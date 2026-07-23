import XCTest
@testable import FerryCore

/// Drives SSHKeyLoader against real keys produced by `ssh-keygen` at runtime
/// (never committed — CLAUDE.md rule 6). Covers the supported algorithms, the
/// passphrase branches the UI depends on, and the unsupported-type rejections.
final class SSHKeyLoaderTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(Self.sshKeygenAvailable, "ssh-keygen not available")
    }

    func testEd25519Unencrypted() throws {
        let pem = try Self.generateKey(type: "ed25519", passphrase: "")
        XCTAssertFalse(try SSHKeyLoader.isEncrypted(pem: pem))
        XCTAssertNoThrow(try SSHKeyLoader.authenticationMethod(username: "ferry", pem: pem, passphrase: nil))
    }

    func testRSAUnencrypted() throws {
        let pem = try Self.generateKey(type: "rsa", bits: "2048", passphrase: "")
        XCTAssertFalse(try SSHKeyLoader.isEncrypted(pem: pem))
        XCTAssertNoThrow(try SSHKeyLoader.authenticationMethod(username: "ferry", pem: pem, passphrase: nil))
    }

    func testEncryptedKeyPassphraseBranches() throws {
        let pem = try Self.generateKey(type: "ed25519", passphrase: "hunter2")
        XCTAssertTrue(try SSHKeyLoader.isEncrypted(pem: pem))

        XCTAssertThrowsError(try SSHKeyLoader.authenticationMethod(
            username: "ferry", pem: pem, passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyLoadError, .passphraseRequired)
        }
        XCTAssertThrowsError(try SSHKeyLoader.authenticationMethod(
            username: "ferry", pem: pem, passphrase: "wrong")) {
            XCTAssertEqual($0 as? SSHKeyLoadError, .incorrectPassphrase)
        }
        XCTAssertNoThrow(try SSHKeyLoader.authenticationMethod(
            username: "ferry", pem: pem, passphrase: "hunter2"))
    }

    func testECDSAIsRejectedAsUnsupported() throws {
        let pem = try Self.generateKey(type: "ecdsa", bits: "256", passphrase: "")
        XCTAssertThrowsError(try SSHKeyLoader.authenticationMethod(
            username: "ferry", pem: pem, passphrase: nil)) { error in
            guard case SSHKeyLoadError.unsupportedKeyType = error else {
                return XCTFail("expected unsupportedKeyType, got \(error)")
            }
        }
    }

    func testCRLFKeyLoads() throws {
        // A key copied through Windows (e.g. exported next to a WinSCP setup)
        // arrives with CRLF endings. Swift folds "\r\n" into one Character, so
        // a split on "\n" would leave the PEM as one line and fail to decode.
        let pem = try Self.generateKey(type: "ed25519", passphrase: "")
        let crlf = Data(String(decoding: pem, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: "\r\n").utf8)
        XCTAssertFalse(try SSHKeyLoader.isEncrypted(pem: crlf))
        XCTAssertNoThrow(try SSHKeyLoader.authenticationMethod(username: "ferry", pem: crlf, passphrase: nil))
    }

    func testGarbageIsRejected() {
        let pem = Data("not a key".utf8)
        XCTAssertThrowsError(try SSHKeyLoader.authenticationMethod(
            username: "ferry", pem: pem, passphrase: nil))
    }

    // MARK: ssh-keygen helper

    private static var sshKeygenAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")
    }

    /// Runs ssh-keygen into a temp dir and returns the private-key bytes.
    private static func generateKey(type: String, bits: String? = nil,
                                    passphrase: String) throws -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-keygen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appendingPathComponent("id").path

        var args = ["-t", type, "-N", passphrase, "-C", "ferry-test", "-f", keyPath, "-q"]
        if let bits { args.insert(contentsOf: ["-b", bits], at: 2) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("ssh-keygen failed for type \(type)")
        }
        return try Data(contentsOf: URL(fileURLWithPath: keyPath))
    }
}
