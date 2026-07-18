import XCTest
@testable import FerryCore

/// Integration tests for `TunnelEngine` against the exec-capable SSH server
/// (:2223, `AllowTcpForwarding yes`). Each test proves a real TCP round trip
/// through a forward by reading the container's own sshd banner
/// (localhost:22 from the server's side) back through the tunnel. M14, ADR-021.
final class TunnelIntegrationTests: XCTestCase {

    private func phase(_ engine: TunnelEngine, _ id: UUID) async -> TunnelStatus.Phase? {
        await engine.statuses().first { $0.id == id }?.phase
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

    /// Remote forwarding is deferred (Citadel exposes no client tcpip-forward,
    /// ADR-021): starting one reports a clear not-supported failure.
    func testRemoteForwardReportsUnsupported() async throws {
        _ = try requireGreetingForExec()
        let engine = TestServers.makeTunnelEngine()
        defer { Task { await engine.shutdown() } }

        let remote = TunnelConfiguration(kind: .remote, listenPort: 18080,
                                         destinationHost: "127.0.0.1", destinationPort: 3000)
        await engine.start(remote)
        guard case .failed(let message) = await phase(engine, remote.id) else {
            return XCTFail("remote forward should report failed")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("supported"),
                      "expected a not-supported message, got: \(message)")
    }

    private func requireGreetingForExec() throws -> String {
        try TestServers.requireGreeting(port: TestServers.scpPort, serverName: "SSH/exec")
    }
}
