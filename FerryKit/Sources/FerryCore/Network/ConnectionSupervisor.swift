import Foundation

/// What the supervisor needs from a live connection: a protocol-level no-op
/// to prove liveness, and a way to rebuild the transport in place.
/// `SFTPSource` conforms; FTP (M12) and SCP (M13) will too.
public protocol SupervisedConnection: Sendable {
    /// Cheap protocol-level no-op (SFTP: `realpath .`). Throws when the
    /// connection is dead.
    func ping() async throws
    /// Tears down and rebuilds the underlying transport with the original
    /// parameters. After it returns, the connection object is usable again.
    func reestablish() async throws
    /// Closes the connection for good (on tab close / app quit). Lets a browser
    /// session tear down its remote source through the protocol, without
    /// knowing whether it's SFTP or FTP.
    func disconnect() async
}

/// Keep-alive + auto-reconnect (DOMAIN.md → Connection lifecycle): pings
/// every `pingInterval` (30 s) while healthy; on a failed ping — or an
/// external `noteFailure()` from a failed transfer/listing — reconnects with
/// exponential backoff, `maxAttempts` (3) tries. State is streamed so the UI
/// can show "Reconnecting…" and reload panes after recovery.
public actor ConnectionSupervisor {
    public enum State: Sendable, Equatable {
        case connected
        case reconnecting(attempt: Int)
        /// All reconnect attempts failed; `reconnectNow()` tries again.
        case lost
    }

    private let connection: any SupervisedConnection
    private let pingInterval: Duration
    private let maxAttempts: Int
    /// Attempt n waits `backoff × 2^(n−1)` before trying.
    private let backoff: Duration

    public private(set) var state: State = .connected
    private var keepAliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<State>.Continuation] = [:]

    public init(connection: any SupervisedConnection,
                pingInterval: Duration = .seconds(30),
                maxAttempts: Int = 3,
                backoff: Duration = .seconds(1)) {
        self.connection = connection
        self.pingInterval = pingInterval
        self.maxAttempts = max(1, maxAttempts)
        self.backoff = backoff
    }

    /// Starts the keep-alive loop. Call once after connecting; `stop()` on
    /// disconnect.
    public func start() {
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { await keepAliveLoop() }
    }

    public func stop() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// State stream; replays the current state on subscription.
    public func events() -> AsyncStream<State> {
        AsyncStream { continuation in
            let token = UUID()
            subscribers[token] = continuation
            continuation.onTermination = { _ in
                Task { await self.dropSubscriber(token) }
            }
            continuation.yield(state)
        }
    }

    /// External failure signal (a transfer or listing threw an I/O error).
    /// No-op while a reconnect cycle is already running or the link is lost.
    public func noteFailure() {
        guard state == .connected else { return }
        beginReconnect()
    }

    /// Manual retry from the UI after the link was declared lost.
    public func reconnectNow() {
        guard reconnectTask == nil else { return }
        beginReconnect()
    }

    private func keepAliveLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: pingInterval)
            guard !Task.isCancelled else { return }
            guard state == .connected else { continue }
            do {
                try await connection.ping()
            } catch {
                beginReconnect()
            }
        }
    }

    private func beginReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { await reconnectCycle() }
    }

    private func reconnectCycle() async {
        defer { reconnectTask = nil }
        for attempt in 1...maxAttempts {
            setState(.reconnecting(attempt: attempt))
            try? await Task.sleep(for: backoff * (1 << (attempt - 1)))
            guard !Task.isCancelled else { return }
            do {
                try await connection.reestablish()
                setState(.connected)
                return
            } catch {
                continue
            }
        }
        setState(.lost)
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        for continuation in subscribers.values {
            continuation.yield(new)
        }
    }

    private func dropSubscriber(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }
}
