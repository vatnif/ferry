import XCTest
@testable import FerryCore

/// Remote-forward configuration validation (M14.5, ADR-022) runs before the
/// engine dials its SSH session, so these tests need no server — the engine
/// points at an unroutable port and would fail differently if it tried to
/// connect.
final class TunnelRemoteValidationTests: XCTestCase {

    private func makeEngine() -> TunnelEngine {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-remote-validation-\(UUID().uuidString)")
        return TunnelEngine(host: "127.0.0.1", port: 1, username: "nobody",
                            credential: .password("unused"),
                            hostKeyStore: HostKeyStore(fileURL: url))
    }

    private func failureMessage(starting config: TunnelConfiguration) async -> String? {
        let engine = makeEngine()
        await engine.start(config)
        let phase = await engine.statuses().first { $0.id == config.id }?.phase
        await engine.shutdown()
        guard case .failed(let message) = phase else { return nil }
        return message
    }

    func testRemoteWithoutDestinationFails() async {
        let message = await failureMessage(
            starting: TunnelConfiguration(kind: .remote, listenPort: 9000))
        XCTAssertTrue(message?.localizedCaseInsensitiveContains("destination") ?? false,
                      "expected a destination validation message, got: \(message ?? "nil")")
    }

    func testRemoteWithServerChosenPortFails() async {
        // Citadel dispatches forwarded-tcpip channels by the requested
        // (host, port) pair, so "let the server pick" (port 0) can never work.
        let message = await failureMessage(
            starting: TunnelConfiguration(kind: .remote, listenPort: 0,
                                          destinationHost: "127.0.0.1", destinationPort: 3000))
        XCTAssertTrue(message?.localizedCaseInsensitiveContains("listen port") ?? false,
                      "expected a listen-port validation message, got: \(message ?? "nil")")
    }
}
