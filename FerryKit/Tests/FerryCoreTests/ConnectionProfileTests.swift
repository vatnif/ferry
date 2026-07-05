import XCTest
@testable import FerryCore

final class ConnectionProfileTests: XCTestCase {
    func testDefaultPortsPerProtocol() {
        XCTAssertEqual(TransferProtocol.sftp.defaultPort, 22)
        XCTAssertEqual(TransferProtocol.scp.defaultPort, 22)
        XCTAssertEqual(TransferProtocol.ftp.defaultPort, 21)
        XCTAssertEqual(TransferProtocol.ftps.defaultPort, 990)
    }

    func testInitAppliesSchemeDefaultPortWhenPortOmitted() {
        let sftp = ConnectionProfile(name: "a", scheme: .sftp, host: "h", username: "u")
        XCTAssertEqual(sftp.port, 22)
        let ftps = ConnectionProfile(name: "b", scheme: .ftps, host: "h", username: "u")
        XCTAssertEqual(ftps.port, 990)
        let custom = ConnectionProfile(name: "c", scheme: .sftp, host: "h", port: 2222, username: "u")
        XCTAssertEqual(custom.port, 2222)
    }

    func testSSHFamilyClassification() {
        XCTAssertTrue(TransferProtocol.sftp.usesSSH)
        XCTAssertTrue(TransferProtocol.scp.usesSSH)
        XCTAssertFalse(TransferProtocol.ftp.usesSSH)
        XCTAssertFalse(TransferProtocol.ftps.usesSSH)
    }

    func testCodableRoundTripAllAuthMethods() throws {
        let methods: [AuthenticationMethod] = [
            .password,
            .publicKey(privateKeyPath: "~/.ssh/id_ed25519"),
            .agent,
        ]
        for method in methods {
            let profile = TestFixtures.profile(name: "x", authMethod: method)
            let data = try JSONEncoder().encode(profile)
            let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)
            XCTAssertEqual(decoded, profile)
        }
    }

    func testProfileJSONContainsNoSecretFields() throws {
        // Guard for CLAUDE.md rule 6: the persisted schema must not even have
        // a place to put a secret.
        let profile = TestFixtures.profile(name: "x", authMethod: .publicKey(privateKeyPath: "/k"))
        let json = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        XCTAssertFalse(json.contains("passphrase"))
        XCTAssertFalse(json.contains("secret"))
    }
}
