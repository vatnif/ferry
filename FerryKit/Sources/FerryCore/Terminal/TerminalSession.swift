@preconcurrency import Citadel
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// An interactive remote shell over a **dedicated** SSH session (M15.5,
/// ADR-023) — the engine behind the embedded terminal (DESIGN.md screen 7).
///
/// Like `TunnelEngine` (ADR-021), the session is opened with `SSHClientFactory`
/// (identical host-key TOFU + password/key auth) and reuses the already-resolved
/// credential, so it never re-prompts — and it is independent of the browser's
/// SFTP/SCP session. Bytes flow through Citadel's `withPTY` (pty-req + shell);
/// `resize` sends the protocol's `window-change` request.
///
/// Requires macOS 15: `withPTY` carries the same availability gate as SCP's
/// `withExec` and Citadel exposes no macOS-14 path (ADR-023). The app disables
/// the built-in terminal on macOS 14 with a clear explainer.
///
/// Nothing that passes through the terminal is ever logged, and scrollback is
/// the *view's* in-memory concern — this actor retains no output (rule 6).
@available(macOS 15.0, *)
public actor TerminalSession {
    public enum State: Sendable, Equatable {
        case idle
        case connecting
        /// The shell is up; `send`/`resize` are live.
        case running
        case ended(EndReason)
    }

    public enum EndReason: Sendable, Equatable {
        /// The shell exited (`exit`, EOF, or the user closed the terminal).
        /// The UI shows the ended banner with Restart Session.
        case exited
        /// Connecting failed or the session dropped — user-presentable reason.
        case failed(String)
    }

    private let parameters: SSHConnectionParameters
    private let terminalType: String

    private var state: State = .idle
    private var stateSubscribers: [UUID: AsyncStream<State>.Continuation] = [:]

    /// One output stream for the actor's lifetime — it spans restarts, so the
    /// hosting view keeps a single pump. Never finished on shell end.
    public nonisolated let output: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation

    private var ssh: SSHClient?
    private var writer: TTYStdinWriter?
    private var runTask: Task<Void, Never>?
    /// Out-of-band end evidence: `withPTY`'s cleanup `channel.close()` can throw
    /// "Already closed" once the remote shell has exited, masking (or fabricating)
    /// a thrown error — the ADR-020 lesson. The classifier weighs these flags
    /// above whatever `withPTY` throws.
    private var userTerminated = false
    private var sessionDropped = false

    /// `TTYStdinWriter` wraps a NIO `Channel` (thread-safe entry points) but
    /// isn't marked Sendable; this carries it from the `withPTY` closure onto
    /// the actor — the `TunnelEngine.SendableSSH` idiom.
    private struct SendableWriter: @unchecked Sendable { let writer: TTYStdinWriter }
    /// Citadel's client predates Sendable (ADR-011); carries it into the
    /// nonisolated shell driver.
    private struct SendableClient: @unchecked Sendable { let client: SSHClient }

    public init(host: String,
                port: Int = 22,
                username: String,
                credential: SSHAuthCredential,
                hostKeyStore: HostKeyStore,
                systemKnownHosts: KnownHostsFile? = nil,
                sessionTrusted: HostKeyInfo? = nil,
                terminalType: String = "xterm-256color") {
        self.parameters = SSHConnectionParameters(host: host, port: port, username: username,
                                                  credential: credential, hostKeyStore: hostKeyStore,
                                                  systemKnownHosts: systemKnownHosts,
                                                  sessionTrusted: sessionTrusted)
        self.terminalType = terminalType
        (self.output, self.outputContinuation) = AsyncStream<Data>.makeStream()
    }

    // MARK: Preflight

    /// Validates host trust + authentication and immediately closes — nothing
    /// is kept. Terminal-only connections (screen 7: a shell with no browser)
    /// call this BEFORE opening a window, so the TOFU/credential prompts run
    /// through the app's normal connect flow: throws `hostKeyUnknown`/
    /// `hostKeyChanged`/`authenticationFailed`/`SSHKeyLoadError` exactly like
    /// the browser backends' `connect` (SSHClientFactory is the shared path).
    public static func preflight(host: String,
                                 port: Int = 22,
                                 username: String,
                                 credential: SSHAuthCredential,
                                 hostKeyStore: HostKeyStore,
                                 systemKnownHosts: KnownHostsFile? = nil,
                                 sessionTrusted: HostKeyInfo? = nil) async throws {
        let parameters = SSHConnectionParameters(host: host, port: port, username: username,
                                                 credential: credential, hostKeyStore: hostKeyStore,
                                                 systemKnownHosts: systemKnownHosts,
                                                 sessionTrusted: sessionTrusted)
        let client = try await SSHClientFactory.connect(parameters)
        try? await client.close()
    }

    // MARK: State stream

    /// State stream; replays the current state on subscription (the
    /// `TunnelEngine.events()` pattern).
    public func states() -> AsyncStream<State> {
        AsyncStream { continuation in
            let token = UUID()
            stateSubscribers[token] = continuation
            continuation.onTermination = { _ in
                Task { await self.dropSubscriber(token) }
            }
            continuation.yield(state)
        }
    }

    public var currentState: State { state }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        for continuation in stateSubscribers.values { continuation.yield(new) }
    }

    private func dropSubscriber(_ token: UUID) {
        stateSubscribers.removeValue(forKey: token)
    }

    // MARK: Lifecycle

    /// Connects and starts the shell. No-op while connecting/running; from
    /// `.ended` it starts a fresh session (the Restart Session button).
    public func start(columns: Int, rows: Int) {
        switch state {
        case .connecting, .running: return
        case .idle, .ended: break
        }
        userTerminated = false
        sessionDropped = false
        setState(.connecting)
        runTask = Task { await self.run(columns: columns, rows: rows) }
    }

    /// Sends keystrokes to the shell's stdin. Dropped unless running — the
    /// view only forwards user input while a shell is up.
    public func send(_ data: Data) async {
        guard state == .running, let writer else { return }
        // A write failing means the channel is going down; the read loop is
        // about to end the session with the real reason — nothing to add here.
        try? await writer.write(ByteBuffer(bytes: data))
    }

    /// Propagates a terminal resize (`window-change`). Safe at any time; only
    /// meaningful while running.
    public func resize(columns: Int, rows: Int) async {
        guard state == .running, let writer else { return }
        try? await writer.changeSize(cols: max(2, columns), rows: max(2, rows),
                                     pixelWidth: 0, pixelHeight: 0)
    }

    /// User-initiated close (panel ✕, window close, disconnect): tears the
    /// shell down and ends in `.ended(.exited)`.
    public func terminate() async {
        userTerminated = true
        if let task = runTask {
            // Cancelling ends the withPTY read loop; its cleanup closes the
            // channel. Bounded — a half-dead session could stall the close.
            task.cancel()
            await Self.awaitCompletion(of: task, upTo: 3)
        }
        await closeTransport()
        if case .ended = state {} else { setState(.ended(.exited)) }
    }

    // MARK: Shell run loop

    private func run(columns: Int, rows: Int) async {
        var thrown: Error?
        do {
            let client = try await SSHClientFactory.connect(parameters)
            ssh = client
            // A shell on a dead session would otherwise sleep obliviously
            // (the ADR-022 lesson from remote forwards).
            client.onDisconnect { [weak self] in
                Task { await self?.transportDropped() }
            }
            try await Self.drive(SendableClient(client: client), session: self,
                                 terminalType: terminalType, columns: columns, rows: rows)
        } catch {
            thrown = error
        }
        await finish(thrown: thrown)
    }

    /// Runs `withPTY` outside the actor so its non-Sendable `perform` closure
    /// is formed and consumed in one isolation region (Swift 6); the closure
    /// only hops *into* the actor via `await`.
    private nonisolated static func drive(_ boxed: SendableClient, session: TerminalSession,
                                          terminalType: String, columns: Int, rows: Int) async throws {
        let request = ptyRequest(terminalType: terminalType, columns: columns, rows: rows)
        try await boxed.client.withPTY(request) { inbound, outbound in
            await session.shellEstablished(SendableWriter(writer: outbound))
            for try await chunk in inbound {
                switch chunk {
                case .stdout(let buffer), .stderr(let buffer):
                    await session.emit(buffer)
                }
            }
        }
    }

    private func shellEstablished(_ boxed: SendableWriter) {
        writer = boxed.writer
        if state == .connecting { setState(.running) }
    }

    private func emit(_ buffer: ByteBuffer) {
        outputContinuation.yield(Data(buffer.readableBytesView))
    }

    private func transportDropped() {
        guard !userTerminated, state == .running || state == .connecting else { return }
        sessionDropped = true
        // The read loop usually ends by itself when the channel dies; cancel
        // covers a half-dead transport that never delivers the EOF.
        runTask?.cancel()
    }

    private func finish(thrown: Error?) async {
        let reason = TerminalEndClassifier.endReason(thrown: thrown,
                                                     userTerminated: userTerminated,
                                                     sessionDropped: sessionDropped)
        await closeTransport()
        setState(.ended(reason))
    }

    private func closeTransport() async {
        writer = nil
        runTask = nil
        if let ssh {
            self.ssh = nil
            try? await ssh.close()
        }
    }

    // MARK: PTY request

    /// Built once per `start`; unit-tested. Empty terminal modes — the server
    /// applies its defaults, matching what a plain `ssh host` negotiates.
    static func ptyRequest(terminalType: String, columns: Int, rows: Int)
    -> SSHChannelRequestEvent.PseudoTerminalRequest {
        SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: terminalType,
            terminalCharacterWidth: max(2, columns),
            terminalRowHeight: max(2, rows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
    }

    /// Waits for `task` to finish, giving up after `seconds` (the
    /// `TunnelEngine.awaitCompletion` idiom — `Task.value` can't be bounded).
    private static func awaitCompletion(of task: Task<Void, Never>, upTo seconds: Double) async {
        let resumed = NIOLockedValueBox(false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await task.value
                if resumed.withLockedValue({ let first = !$0; $0 = true; return first }) {
                    continuation.resume()
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if resumed.withLockedValue({ let first = !$0; $0 = true; return first }) {
                    continuation.resume()
                }
            }
        }
    }
}

/// Decides how a terminal session ended. Pure — unit-tested against the error
/// shapes `withPTY` actually produces, because its cleanup `channel.close()`
/// masks thrown errors with "Already closed" once the remote shell has exited
/// (ADR-020/ADR-023): the out-of-band flags outrank the thrown error.
@available(macOS 15.0, *)
enum TerminalEndClassifier {
    static func endReason(thrown: Error?,
                          userTerminated: Bool,
                          sessionDropped: Bool) -> TerminalSession.EndReason {
        if userTerminated { return .exited }
        if sessionDropped { return .failed("The SSH session dropped.") }
        guard let thrown else { return .exited }

        // A non-zero shell exit code is still a normal shell exit.
        if thrown is SSHClient.CommandFailed { return .exited }
        if thrown is CancellationError { return .exited }
        // Artifacts of withPTY's cleanup racing the remote's own close.
        if let channel = thrown as? ChannelError,
           channel == .alreadyClosed || channel == .ioOnClosedChannel { return .exited }
        // The server accepted the channel but refused the shell request
        // (e.g. a ForceCommand/SFTP-only server).
        if case CitadelError.channelFailure = thrown {
            return .failed("The server refused an interactive shell — it may only allow SFTP.")
        }
        if let remote = thrown as? RemoteSourceError { return .failed(describe(remote)) }
        return .failed(String(describing: thrown))
    }

    private static func describe(_ error: RemoteSourceError) -> String {
        switch error {
        case .authenticationFailed:
            return "Authentication failed."
        case .connectionFailed(let reason):
            return "Could not connect: \(reason)"
        case .hostKeyUnknown, .hostKeyChanged:
            // The app resolves trust before opening a terminal; reaching this
            // means the key changed since — never silently accepted.
            return "The server’s host key isn’t trusted."
        case .tlsFailed(let reason):
            return reason
        }
    }
}
