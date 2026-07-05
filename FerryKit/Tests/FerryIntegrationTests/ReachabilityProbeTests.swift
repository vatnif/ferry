import XCTest
@testable import FerryCore

/// M4 integration tests for the TCP probe behind "Test Connection".
final class ReachabilityProbeTests: XCTestCase {
    func testReachesRunningTestServer() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.sftpPort, serverName: "SFTP")
        let result = try await ReachabilityProbe.tcpReachable(host: TestServers.host,
                                                              port: Int(TestServers.sftpPort))
        XCTAssertGreaterThan(result.duration, 0)
        XCTAssertLessThan(result.duration, 5)
    }

    func testRefusedPortFailsQuickly() async {
        // Port 9 (discard) is not served on loopback — connect is refused.
        do {
            _ = try await ReachabilityProbe.tcpReachable(host: "127.0.0.1", port: 9, timeout: 5)
            XCTFail("expected unreachable")
        } catch let error as ReachabilityProbe.ProbeError {
            guard case .unreachable = error else {
                return XCTFail("expected .unreachable, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testInvalidPortIsRejected() async {
        do {
            _ = try await ReachabilityProbe.tcpReachable(host: "127.0.0.1", port: 0)
            XCTFail("expected invalidPort")
        } catch let error as ReachabilityProbe.ProbeError {
            guard case .invalidPort = error else {
                return XCTFail("expected .invalidPort, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
