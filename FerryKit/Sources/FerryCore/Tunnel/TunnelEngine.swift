@preconcurrency import Citadel
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// Live status of one tunnel, streamed to the UI (M14, mockup screen 4).
public struct TunnelStatus: Sendable, Equatable, Identifiable {
    public enum Phase: Sendable, Equatable {
        case stopped
        case starting
        /// Listening and forwarding; `connections` is the live count shown in
        /// the manager's status column.
        case forwarding(connections: Int)
        /// Couldn't start (port in use, remote refusal) or dropped — the reason
        /// surfaces inline in the status column (red).
        case failed(String)
    }
    public var id: UUID
    public var phase: Phase

    public init(id: UUID, phase: Phase) {
        self.id = id
        self.phase = phase
    }
}

/// Manages a connection profile's port forwards over a **dedicated** SSH session
/// (M14, ADR-021). The tunnel session is opened with the same `SSHClientFactory`
/// (host-key TOFU + password/key auth) and reuses the already-resolved
/// credential, so it never re-prompts — but it's independent of the browser's
/// SFTP/SCP session, so tunnels have their own lifecycle and work regardless of
/// what's being browsed.
///
/// The engine, its SSH channel, every `direct-tcpip` forward channel, and the
/// local listener sockets all run on **one dedicated single-thread event-loop
/// group**, which is what lets the `GlueHandler` pair splice a local connection
/// to its SSH channel by touching both contexts directly.
///
/// Supported modes (Citadel 0.12.1 exposes only `direct-tcpip` on the client):
/// - **Local** — bind a loopback listener; each accepted connection opens a
///   `direct-tcpip` channel to a fixed destination reachable from the server.
/// - **SOCKS** — same, but a per-connection SOCKS5 handshake picks the target.
/// - **Remote** — needs the `tcpip-forward` global request, which Citadel keeps
///   internal; deferred to the backlog (ADR-021). Starting one reports failed.
public actor TunnelEngine {
    private let parameters: SSHConnectionParameters
    /// One thread, so all channels share an event loop (see type doc).
    private let group: MultiThreadedEventLoopGroup
    private var ssh: SSHClient?

    private struct RunningTunnel {
        let config: TunnelConfiguration
        let listener: Channel?
        let connections: NIOLockedValueBox<Int>
    }
    private var running: [UUID: RunningTunnel] = [:]
    private var phases: [UUID: TunnelStatus.Phase] = [:]
    private var subscribers: [UUID: AsyncStream<[TunnelStatus]>.Continuation] = [:]

    /// SSHClient is confined to the engine's single event loop; this box carries
    /// it across the `Sendable` boundary of NIO's channel initializers.
    private struct SendableSSH: @unchecked Sendable { let client: SSHClient }

    public init(host: String,
                port: Int = 22,
                username: String,
                credential: SSHAuthCredential,
                hostKeyStore: HostKeyStore,
                systemKnownHosts: KnownHostsFile? = nil,
                sessionTrusted: HostKeyInfo? = nil) {
        self.parameters = SSHConnectionParameters(host: host, port: port, username: username,
                                                  credential: credential, hostKeyStore: hostKeyStore,
                                                  systemKnownHosts: systemKnownHosts,
                                                  sessionTrusted: sessionTrusted)
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    // MARK: Status stream

    /// State stream; replays the current snapshot on subscription.
    public func events() -> AsyncStream<[TunnelStatus]> {
        AsyncStream { continuation in
            let token = UUID()
            subscribers[token] = continuation
            continuation.onTermination = { _ in
                Task { await self.dropSubscriber(token) }
            }
            continuation.yield(snapshot())
        }
    }

    public func statuses() -> [TunnelStatus] { snapshot() }

    private func snapshot() -> [TunnelStatus] {
        phases.map { TunnelStatus(id: $0.key, phase: $0.value) }
    }

    private func setPhase(_ id: UUID, _ phase: TunnelStatus.Phase) {
        guard phases[id] != phase else { return }
        phases[id] = phase
        let snap = snapshot()
        for continuation in subscribers.values { continuation.yield(snap) }
    }

    private func dropSubscriber(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    // MARK: Lifecycle

    /// Starts every enabled tunnel — the "start automatically on connect"
    /// behaviour (DESIGN.md screen 4). Failures land in each tunnel's status.
    public func startEnabled(_ configs: [TunnelConfiguration]) async {
        for config in configs where config.isEnabled {
            await start(config)
        }
    }

    /// Starts one tunnel. No-op if it's already running. Errors (port in use,
    /// unsupported mode) are captured into the tunnel's status, never thrown.
    public func start(_ config: TunnelConfiguration) async {
        guard running[config.id] == nil else { return }
        setPhase(config.id, .starting)
        do {
            switch config.kind {
            case .local:  try await startForward(config, socks: false)
            case .socks:  try await startForward(config, socks: true)
            case .remote:
                setPhase(config.id, .failed("Remote port forwarding isn’t supported yet."))
            }
        } catch {
            setPhase(config.id, .failed(Self.describe(error, listenPort: config.listenPort)))
        }
    }

    public func stop(_ id: UUID) async {
        guard let tunnel = running.removeValue(forKey: id) else {
            // Clear a lingering failed/starting status for a not-actually-running tunnel.
            if phases[id] != nil { setPhase(id, .stopped) }
            return
        }
        try? await tunnel.listener?.close()
        setPhase(id, .stopped)
    }

    public func stopAll() async {
        for id in Array(running.keys) { await stop(id) }
    }

    /// Full teardown on disconnect/quit: stop tunnels, close the SSH session,
    /// and shut the dedicated event-loop group down.
    public func shutdown() async {
        await stopAll()
        try? await ssh?.close()
        ssh = nil
        try? await group.shutdownGracefully()
    }

    // MARK: SSH session (dedicated, lazily established)

    private func ensureConnected() async throws -> SSHClient {
        if let ssh, ssh.isConnected { return ssh }
        let client = try await SSHClientFactory.connect(parameters, group: group)
        ssh = client
        return client
    }

    // MARK: Local / SOCKS forwards

    private func startForward(_ config: TunnelConfiguration, socks: Bool) async throws {
        let ssh = SendableSSH(client: try await ensureConnected())
        let counts = NIOLockedValueBox(0)
        let id = config.id
        // notify() hops back to the actor to recompute the live connection count.
        let notify: @Sendable () -> Void = { [weak self] in
            Task { await self?.connectionCountChanged(id) }
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // SOCKS drives its negotiation reads by hand (autoRead off); a plain
            // local forward rides default autoRead once the glue is in place.
            .childChannelOption(ChannelOptions.autoRead, value: !socks)
            .childChannelInitializer { [weak self] accepted in
                guard let self else { return accepted.eventLoop.makeSucceededVoidFuture() }
                if socks {
                    return Self.installSOCKS(on: accepted, engine: self, ssh: ssh,
                                             counts: counts, notify: notify)
                } else {
                    let promise = accepted.eventLoop.makePromise(of: Void.self)
                    promise.completeWithTask {
                        try await self.bridgeLocal(accepted: accepted, ssh: ssh.client,
                                                   host: config.destinationHost ?? "",
                                                   port: config.destinationPort ?? 0,
                                                   counts: counts, notify: notify)
                    }
                    return promise.futureResult
                }
            }

        if !socks {
            guard config.destinationHost?.isEmpty == false, let port = config.destinationPort, port > 0 else {
                throw TunnelError.invalidConfiguration("A local forward needs a destination host and port.")
            }
        }

        let listener = try await bootstrap.bind(host: config.listenHost, port: config.listenPort).get()
        running[id] = RunningTunnel(config: config, listener: listener, connections: counts)
        setPhase(id, .forwarding(connections: 0))
        // Detect an unexpected listener drop (not via stop()).
        listener.closeFuture.whenComplete { [weak self] _ in
            Task { await self?.listenerClosed(id) }
        }
    }

    /// Installs the SOCKS5 negotiator on an accepted proxy connection; on
    /// CONNECT it bridges to a `direct-tcpip` channel and answers the client.
    private static func installSOCKS(on accepted: Channel, engine: TunnelEngine,
                                     ssh: SendableSSH, counts: NIOLockedValueBox<Int>,
                                     notify: @escaping @Sendable () -> Void) -> EventLoopFuture<Void> {
        let handler = SOCKSServerHandler { target, channel, leftover in
            let promise = channel.eventLoop.makePromise(of: Void.self)
            promise.completeWithTask {
                try await engine.bridgeSOCKS(accepted: channel, target: target, leftover: leftover,
                                             ssh: ssh.client, counts: counts, notify: notify)
            }
            promise.futureResult.whenFailure { _ in
                var reply = channel.allocator.buffer(capacity: 10)
                reply.writeBytes(SOCKSProxy.connectReply(.connectionRefused))
                channel.writeAndFlush(reply).whenComplete { _ in channel.close(promise: nil) }
            }
        }
        return accepted.pipeline.addHandler(handler)
    }

    private func listenerClosed(_ id: UUID) {
        // Only surface as an error if we didn't stop it ourselves.
        guard running[id] != nil else { return }
        running.removeValue(forKey: id)
        setPhase(id, .failed("The tunnel’s listener stopped unexpectedly."))
    }

    private func connectionCountChanged(_ id: UUID) {
        guard let tunnel = running[id] else { return }
        setPhase(id, .forwarding(connections: tunnel.connections.withLockedValue { $0 }))
    }

    // MARK: Channel bridging (nonisolated: runs off the actor, on NIO futures)

    /// Opens a `direct-tcpip` channel to `host:port` and installs `sshGlue` on
    /// it before it becomes active. `holdReads` starts the channel with autoRead
    /// off (SOCKS: the server's first bytes must wait until the reply is sent);
    /// a local forward leaves autoRead on so the flow starts by itself. Both
    /// channels are on the engine's single event loop.
    private nonisolated func openForwardChannel(ssh: SSHClient, host: String, port: Int,
                                                sshGlue: GlueHandler, holdReads: Bool)
    async throws -> Channel {
        let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let settings = SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port,
                                                  originatorAddress: origin)
        return try await ssh.createDirectTCPIPChannel(using: settings) { channel in
            channel.setOption(ChannelOptions.autoRead, value: !holdReads).flatMap {
                channel.pipeline.addHandler(sshGlue)
            }
        }
    }

    /// Bumps the live count and arranges the decrement on close.
    private nonisolated func trackConnection(_ accepted: Channel, counts: NIOLockedValueBox<Int>,
                                             notify: @escaping @Sendable () -> Void) {
        counts.withLockedValue { $0 += 1 }
        notify()
        accepted.closeFuture.whenComplete { _ in
            counts.withLockedValue { $0 -= 1 }
            notify()
        }
    }

    private nonisolated func bridgeLocal(accepted: Channel, ssh: SSHClient, host: String, port: Int,
                                         counts: NIOLockedValueBox<Int>,
                                         notify: @escaping @Sendable () -> Void) async throws {
        let (localGlue, sshGlue) = GlueHandler.matchedPair()
        // Install the local-side glue BEFORE the SSH channel exists, so the
        // server's opening bytes have somewhere to go the instant the SSH
        // channel goes active (otherwise the first read is dropped). The
        // accepted channel doesn't start reading until this initializer's
        // future succeeds, so ordering is safe.
        try await accepted.pipeline.addHandler(localGlue).get()
        _ = try await openForwardChannel(ssh: ssh, host: host, port: port,
                                         sshGlue: sshGlue, holdReads: false)
        trackConnection(accepted, counts: counts, notify: notify)
    }

    private nonisolated func bridgeSOCKS(accepted: Channel, target: SOCKSProxy.Target,
                                         leftover: ByteBuffer, ssh: SSHClient,
                                         counts: NIOLockedValueBox<Int>,
                                         notify: @escaping @Sendable () -> Void) async throws {
        let (localGlue, sshGlue) = GlueHandler.matchedPair()
        // Hold the SSH channel's reads: the SOCKS success reply must reach the
        // client before any forwarded server bytes do.
        let sshChannel = try await openForwardChannel(ssh: ssh, host: target.host, port: target.port,
                                                      sshGlue: sshGlue, holdReads: true)
        var reply = accepted.allocator.buffer(capacity: 10)
        reply.writeBytes(SOCKSProxy.connectReply(.succeeded))
        try await accepted.writeAndFlush(reply).get()
        // Replay any bytes the client pipelined after its request onto the SSH
        // channel, then splice. The SOCKS handler passes reads through once
        // done, so it can stay in the pipeline ahead of the glue.
        if leftover.readableBytes > 0 {
            try await sshChannel.writeAndFlush(leftover).get()
        }
        try await accepted.pipeline.addHandler(localGlue).get()
        // Both glues are in place and the reply is sent — let the data flow.
        // The accepted channel negotiated with autoRead off, and the SSH channel
        // was held; enable autoRead on both and prime one read each (setting
        // autoRead on an already-active channel doesn't itself issue a read).
        try await accepted.setOption(ChannelOptions.autoRead, value: true).get()
        try await sshChannel.setOption(ChannelOptions.autoRead, value: true).get()
        accepted.read()
        sshChannel.read()
        trackConnection(accepted, counts: counts, notify: notify)
    }

    // MARK: Errors

    enum TunnelError: Error { case invalidConfiguration(String) }

    private static func describe(_ error: Error, listenPort: Int) -> String {
        if let io = error as? IOError, io.errnoCode == EADDRINUSE {
            return "Port \(listenPort) is already in use."
        }
        if let io = error as? IOError, io.errnoCode == EACCES {
            return "Permission denied binding port \(listenPort) (ports below 1024 need privileges)."
        }
        if case TunnelError.invalidConfiguration(let message) = error { return message }
        return String(describing: error)
    }
}
