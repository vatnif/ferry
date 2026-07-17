import XCTest
@testable import FerryCore

/// Exercises the read-only OpenSSH `known_hosts` parser Ferry uses to pre-trust
/// hosts (M11 checkpoint B). The hashed-entry vectors were produced by
/// `ssh-keygen -H`, so this pins Ferry's HMAC-SHA1 matching to OpenSSH's own.
final class KnownHostsFileTests: XCTestCase {
    // ssh-ed25519 test key (same vector as HostKeyInfoTests).
    private let key =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINPThizqWf0Z6Lvo9v8G5cPHYG667J3hD7XRkVP/e4k/"
    private let sha256 = "SHA256:DtssY9xVYOU71AmcKfdqhByuOFqtYIcU9DdDTwukNgk"

    // MARK: Plaintext entries

    func testPlaintextMatchAtDefaultPort() {
        let file = KnownHostsFile(text: "example.com \(key)\n")
        XCTAssertTrue(file.contains(host: "example.com", port: 22))
        XCTAssertEqual(file.storedInfos(host: "example.com", port: 22).first?.sha256, sha256)
        // A different host / a non-default port for a :22 entry must not match.
        XCTAssertFalse(file.contains(host: "other.com", port: 22))
        XCTAssertFalse(file.contains(host: "example.com", port: 2222))
    }

    func testPlaintextMatchAtNonDefaultPort() {
        let file = KnownHostsFile(text: "[example.com]:2222 \(key)\n")
        XCTAssertTrue(file.contains(host: "example.com", port: 2222))
        XCTAssertFalse(file.contains(host: "example.com", port: 22))
    }

    func testCommaSeparatedHostList() {
        let file = KnownHostsFile(text: "alias,example.com,10.0.0.5 \(key)\n")
        XCTAssertTrue(file.contains(host: "example.com", port: 22))
        XCTAssertTrue(file.contains(host: "10.0.0.5", port: 22))
        XCTAssertTrue(file.contains(host: "alias", port: 22))
    }

    func testMatchingIsCaseInsensitive() {
        let file = KnownHostsFile(text: "Example.COM \(key)\n")
        XCTAssertTrue(file.contains(host: "example.com", port: 22))
    }

    // MARK: Hashed entries (vectors from `ssh-keygen -H`)

    func testHashedMatchAtDefaultPort() {
        // ssh-keygen -H over "example.com <key>"
        let file = KnownHostsFile(text:
            "|1|mwV//CBiMUYuDHxu0WjaNglCyfI=|fi1qRYYP1UjnS376GzuEvX64KEE= \(key)\n")
        XCTAssertTrue(file.contains(host: "example.com", port: 22))
        XCTAssertEqual(file.storedInfos(host: "example.com", port: 22).first?.sha256, sha256)
        XCTAssertFalse(file.contains(host: "evil.com", port: 22))
    }

    func testHashedMatchAtNonDefaultPort() {
        // ssh-keygen -H over "[example.com]:2222 <key>"
        let file = KnownHostsFile(text:
            "|1|xQVzaRal/4BELK/7Eo+vIm2lYl8=|FogHtns4sG9YLLQD28rkLeT/0AU= \(key)\n")
        XCTAssertTrue(file.contains(host: "example.com", port: 2222))
        XCTAssertFalse(file.contains(host: "example.com", port: 22))
    }

    // MARK: Robustness

    func testCommentsBlanksAndMarkersAreSkipped() {
        let text = """
        # a comment
        @cert-authority example.com \(key)
        @revoked example.com \(key)

        example.com \(key)
        """
        let file = KnownHostsFile(text: text)
        // Only the plain entry counts — CA/revoked markers are ignored.
        XCTAssertEqual(file.storedInfos(host: "example.com", port: 22).count, 1)
    }

    func testEmptyAndUnparseableInputYieldEmptyFile() {
        XCTAssertTrue(KnownHostsFile(text: "").isEmpty)
        XCTAssertTrue(KnownHostsFile(text: "\n#only a comment\n   \n").isEmpty)
        // A truncated line (no key body) is dropped, not fatal.
        XCTAssertTrue(KnownHostsFile(text: "example.com ssh-ed25519\n").isEmpty)
    }

    func testMissingFileYieldsEmptyFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-no-such-known_hosts-\(UUID().uuidString)")
        XCTAssertTrue(KnownHostsFile(contentsOf: url).isEmpty)
    }
}
