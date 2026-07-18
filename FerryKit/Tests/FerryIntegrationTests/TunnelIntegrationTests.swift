import XCTest
@testable import FerryCore

/// Integration tests for `TunnelEngine` against the exec-capable SSH server
/// (:2223, `AllowTcpForwarding yes` + `GatewayPorts clientspecified`). Each
/// test proves a real TCP round trip through a forward by reading an sshd
/// banner back through the tunnel: local/SOCKS reach the container's own sshd
/// (localhost:22 from the server's side); remote forwards run the loop the
/// other way (host :2224 → container listener :18080 → forwarded-tcpip →
/// engine → host-mapped sshd :2223). M14, ADR-021; remote M14.5, ADR-022.
final class TunnelIntegrationTests: XCTestCase {

    private func phase(_ engine: TunnelEngine, _ id: UUID) async -> TunnelStatus.Phase? {
        await engine.statuses().first { $0.id == id }?.phase
    }

    /// Polls until the tunnel's phase satisfies `predicate` (remote forwards
    /// settle asynchronously: `start()` returns while still `.starting`).
    private func waitForPhase(_ engine: TunnelEngine, _ id: UUID,
                              timeoutSeconds: Double = 8,
                              until predicate: (TunnelStatus.Phase?) -> Bool) async -> TunnelStatus.Phase? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let current = await phase(engine, id)
            if predicate(current) { return current }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await phase(engine, id)
    }

    /// Local forward: a loopback listener whose accepted connections reach a
    /// destination the SSH server can see. Forwarding to the server's own sshd
    /// (127.0.0.1:22) lets us read a deterministic SSH banner back.
    func testLocalForwardRoundTrip() async throws {
        _ = try requireGreetingForExec()
        try await TestServers.trustSSHExecHostKey()

        let engine = TestServers.makeTunnelEngine()
        let listenPort = TestServers.freeLocalPort()
        let config = TunnelConfiguration(kind: .local, listenPort: Int(listenPort),
                                         destinationHost: "127.0.0.1", destinationPort: 22)
        await engine.start(config)
        defer { Task { await engine.shutdown() } }

        let started = await phase(engine, config.id)
        guard case .forwarding = started else {
            return XCTFail("tunnel did not reach forwarding: \(String(describing: started))")
        }

        let banner = TestServers.readGreeting(port: listenPort)
        XCTAssertNotNil(banner, "no banner came back through the local forward")
        XCTAssertTrue(banner?.hasPrefix("SSH-2.0") ?? false,
                      "expected an SSH banner through the tunnel, got: \(banner ?? "nil")")

        await engine.stop(config.id)
        let stopped = await phase(engine, config.id)
        XCTAssertEqual(stopped, .stopped)
        // Port is released: a fresh connect finds nothing listening.
        XCTAssertNil(TestServers.readGreeting(port: listenPort, timeoutSeconds: 1),
                     "the listener port should be free after stop()")
    }

    /// SOCKS proxy: negotiate SOCKS5 to the same target and read its banner.
    func testSOCKSForwardRoundTrip() async throws {
        _ = try requireGreetingForExec()
        try await TestServers.trustSSHExecHostKey()

        let engine = TestServers.makeTunnelEngine()
        let listenPort = TestServers.freeLocalPort()
        let config = TunnelConfiguration(kind: .socks, listenPort: Int(listenPort))
        await engine.start(config)
        defer { Task { await engine.shutdown() } }

        guard case .forwarding = await phase(engine, config.id) else {
            return XCTFail("SOCKS tunnel did not reach forwarding")
        }

        let banner = TestServers.socksConnectGreeting(proxyPort: listenPort,
                                                      targetHost: "127.0.0.1", targetPort: 22)
        XCTAssertTrue(banner?.hasPrefix("SSH-2.0") ?? false,
                      "expected an SSH banner through the SOCKS proxy, got: \(banner ?? "nil")")
    }

    /// A second tunnel on an already-bound port surfaces a clear failure rather
    /// than throwing (DESIGN.md: errors show inline in the status column).
    func testPortInUseReported() async throws {
        _ = try requireGreetingForExec()
        try await TestServers.trustSSHExecHostKey()

        let engine = TestServers.makeTunnelEngine()
        defer { Task { await engine.shutdown() } }

        let listenPort = TestServers.freeLocalPort()
        let first = TunnelConfiguration(kind: .local, listenPort: Int(listenPort),
                                        destinationHost: "127.0.0.1", destinationPort: 22)
        await engine.start(first)
        guard case .forwarding = await phase(engine, first.id) else {
            return XCTFail("first tunnel did not start")
        }

        let clash = TunnelConfiguration(kind: .local, listenPort: Int(listenPort),
                                        destinationHost: "127.0.0.1", destinationPort: 22)
        await engine.start(clash)
        guard case .failed(let message) = await phase(engine, clash.id) else {
            return XCTFail("expected the clashing tunnel to fail")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("in use"),
                      "failure should mention the port is in use, got: \(message)")
    }

    /// `startEnabled` brings up enabled tunnels and leaves disabled ones alone.
    func testStartEnabledSkipsDisabled() async throws {
        _ = try requireGreetingForExec()
        try await TestServers.trustSSHExecHostKey()

        let engine = TestServers.makeTunnelEngine()
        defer { Task { await engine.shutdown() } }

        let enabled = TunnelConfiguration(kind: .local, listenPort: Int(TestServers.freeLocalPort()),
                                          destinationHost: "127.0.0.1", destinationPort: 22,
                                          isEnabled: true)
        let disabled = TunnelConfiguration(kind: .local, listenPort: Int(TestServers.freeLocalPort()),
                                           destinationHost: "127.0.0.1", destinationPort: 22,
                                           isEnabled: false)
        await engine.startEnabled([enabled, disabled])

        guard case .forwarding = await phase(engine, enabled.id) else {
            return XCTFail("the enabled tunnel should be forwarding")
        }
        // The disabled tunnel was never started, so the engine isn't tracking it.
        let disabledPhase = await phase(engine, disabled.id)
        XCTAssertNil(disabledPhase)
    }

    /// Remote forward (M14.5, ADR-022): sshd listens on container :18080
    /// (reached from the host via the :2224 mapping) and each connection comes
    /// back as a `forwarded-tcpip` channel that the engine bridges to the
    /// host-mapped sshd on 127.0.0.1:2223 — so the banner proves the full loop.
    /// Stopping must release the server-side listener.
    func testRemoteForwardRoundTrip() async throws {
        _ = try requireGreetingForExec()
        try await TestServers.trustSSHExecHostKey()

        let engine = TestServers.makeTunnelEngine()
        let config = TunnelConfiguration(kind: .remote, listenHost: "0.0.0.0",
                                         listenPort: TestServers.remoteForwardServerPort,
                                         destinationHost: "127.0.0.1",
                                         destinationPort: Int(TestServers.scpPort))
        await engine.start(config)
        defer { Task { await engine.shutdown() } }

        let started = await waitForPhase(engine, config.id) { $0 != .starting }
        guard case .forwarding = started else {
            return XCTFail("remote tunnel did not reach forwarding: \(String(describing: started))")
        }

        let banner = TestServers.readGreeting(port: TestServers.remoteForwardHostPort)
        XCTAssertNotNil(banner, "no banner came back through the remote forward")
        XCTAssertTrue(banner?.hasPrefix("SSH-2.0") ?? false,
                      "expected an SSH banner through the remote forward, got: \(banner ?? "nil")")

        await engine.stop(config.id)
        let stopped = await phase(engine, config.id)
        XCTAssertEqual(stopped, .stopped)
        // The server-side listener is gone. Docker's proxy may still accept and
        // then reset, so assert "no banner", not "connection refused".
        XCTAssertNil(TestServers.readGreeting(port: TestServers.remoteForwardHostPort,
                                              timeoutSeconds: 1),
                     "the server-side port should be released after stop()")
    }

    /// A `tcpip-forward` request the server can't honor (port 22 is sshd's own)
    /// surfaces as a clear refusal in the status column.
    func testRemoteForwardRefusalReported() async throws {
        _ = try requireGreetingForExec()
        try await TestServers.trustSSHExecHostKey()

        let engine = TestServers.makeTunnelEngine()
        defer { Task { await engine.shutdown() } }

        let config = TunnelConfiguration(kind: .remote, listenHost: "0.0.0.0", listenPort: 22,
                                         destinationHost: "127.0.0.1",
                                         destinationPort: Int(TestServers.scpPort))
        await engine.start(config)
        let settled = await waitForPhase(engine, config.id) { $0 != .starting }
        guard case .failed(let message) = settled else {
            return XCTFail("expected the remote forward to fail, got: \(String(describing: settled))")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("refused"),
                      "failure should mention the server refused, got: \(message)")
    }

    /// The live connection count feeds the status column ("forwarding · N conns").
    func testRemoteForwardTracksConnections() async throws {
        _ = try requireGreetingForExec()
        try await TestServers.trustSSHExecHostKey()

        let engine = TestServers.makeTunnelEngine()
        let config = TunnelConfiguration(kind: .remote, listenHost: "0.0.0.0",
                                         listenPort: TestServers.remoteForwardServerPort,
                                         destinationHost: "127.0.0.1",
                                         destinationPort: Int(TestServers.scpPort))
        await engine.start(config)
        defer { Task { await engine.shutdown() } }

        guard case .forwarding = await waitForPhase(engine, config.id, until: { $0 != .starting }) else {
            return XCTFail("remote tunnel did not reach forwarding")
        }

        guard let fd = TestServers.holdOpenConnection(port: TestServers.remoteForwardHostPort) else {
            return XCTFail("couldn't open a connection through the remote forward")
        }
        let one = await waitForPhase(engine, config.id) { $0 == .forwarding(connections: 1) }
        XCTAssertEqual(one, .forwarding(connections: 1))

        close(fd)
        let zero = await waitForPhase(engine, config.id) { $0 == .forwarding(connections: 0) }
        XCTAssertEqual(zero, .forwarding(connections: 0))
    }

    private func requireGreetingForExec() throws -> String {
        try TestServers.requireGreeting(port: TestServers.scpPort, serverName: "SSH/exec")
    }
}
