import XCTest

/// M1 smoke tests: prove the integration-test infrastructure works end to end
/// (Docker containers up, ports mapped, protocols answering). Real protocol
/// tests replace these gradually from M6 (SFTP) and M12 (FTP).
final class TestServerReachabilityTests: XCTestCase {
    func testSFTPServerSpeaksSSH() throws {
        let greeting = try TestServers.requireGreeting(port: TestServers.sftpPort, serverName: "SFTP")
        XCTAssertTrue(greeting.hasPrefix("SSH-2.0"),
                      "Expected an SSH-2.0 banner, got: \(greeting)")
    }

    func testFTPServerGreets() throws {
        let greeting = try TestServers.requireGreeting(port: TestServers.ftpPort, serverName: "FTP")
        XCTAssertTrue(greeting.hasPrefix("220"),
                      "Expected a 220 FTP greeting, got: \(greeting)")
    }
}
