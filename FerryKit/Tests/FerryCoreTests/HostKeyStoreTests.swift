import XCTest
@testable import FerryCore

/// Exercises Ferry's own known_hosts store on a real temp file: trust,
/// idempotence, per-endpoint scoping, replace and remove — the operations the
/// TOFU flow drives.
final class HostKeyStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: HostKeyStore!

    private let keyA = HostKeyInfo(openSSHLine:
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINPThizqWf0Z6Lvo9v8G5cPHYG667J3hD7XRkVP/e4k/")!
    private let keyB = HostKeyInfo(openSSHLine:
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCr0tPPLjuXyrOAq9uSW8vzi+x+GNBRe7o9JF7YxNJncOejxCue9CVDUsMNgAknoIcRRdde7XAc4a8KfQ7TXqd5KzEacpU8W/DJHMea4RqYwPvpLs42gxMdPKac9UJEncAuZWky0q+YHTzWXDl7AxlarM8welsijEDfao2SX2MMjAybN1M9NCcLIYfefT/lcPWLw5elbz9QZtHCLXCUzf8JRopKKJ6NnuiSWj/4dnEzZgS13nxv+7/9OE9CznOyKXxxs0iAKJGVMSxozDPEsdGYBVCwY6JkJc7TVDQWx9n/DIZ3BlZAtTBcZ8yBYRlX+xpHJHKHNbboJ/0kCYBe7PR/")!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-known_hosts-\(UUID().uuidString)")
        store = HostKeyStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    func testMissingFileIsEmpty() throws {
        XCTAssertFalse(try store.contains(host: "example.com", port: 22))
        XCTAssertEqual(try store.storedInfos(host: "example.com", port: 22), [])
        XCTAssertEqual(try store.trustedKeys(host: "example.com", port: 22).count, 0)
    }

    func testParseHostSpec() {
        XCTAssertEqual(HostKeyStore.parseHostSpec("example.com")?.host, "example.com")
        XCTAssertEqual(HostKeyStore.parseHostSpec("example.com")?.port, 22)
        XCTAssertEqual(HostKeyStore.parseHostSpec("[example.com]:2222")?.host, "example.com")
        XCTAssertEqual(HostKeyStore.parseHostSpec("[example.com]:2222")?.port, 2222)
        // Hashed / malformed specs are not listable.
        XCTAssertNil(HostKeyStore.parseHostSpec("|1|abc=|def="))
        XCTAssertNil(HostKeyStore.parseHostSpec("[example.com]:notaport"))
    }

    func testAllTrustedHosts() throws {
        try store.trust(keyA, host: "example.com", port: 22)
        try store.trust(keyB, host: "gate.internal", port: 2222)
        let hosts = try store.allTrustedHosts().sorted { $0.host < $1.host }
        XCTAssertEqual(hosts.count, 2)
        XCTAssertEqual(hosts[0].host, "example.com")
        XCTAssertEqual(hosts[0].port, 22)
        XCTAssertEqual(hosts[0].endpoint, "example.com")
        XCTAssertEqual(hosts[1].host, "gate.internal")
        XCTAssertEqual(hosts[1].port, 2222)
        XCTAssertEqual(hosts[1].endpoint, "gate.internal:2222")
        // Removing an endpoint drops it from the list.
        try store.remove(host: "example.com", port: 22)
        XCTAssertEqual(try store.allTrustedHosts().count, 1)
    }

    func testTrustRoundTrip() throws {
        try store.trust(keyA, host: "example.com", port: 22)
        XCTAssertTrue(try store.contains(host: "example.com", port: 22))
        XCTAssertEqual(try store.storedInfos(host: "example.com", port: 22), [keyA])
        XCTAssertEqual(try store.trustedKeys(host: "example.com", port: 22).count, 1)
        // Survives a fresh reader over the same file.
        let reopened = HostKeyStore(fileURL: fileURL)
        XCTAssertEqual(try reopened.storedInfos(host: "example.com", port: 22), [keyA])
    }

    func testTrustIsIdempotent() throws {
        try store.trust(keyA, host: "example.com", port: 22)
        try store.trust(keyA, host: "example.com", port: 22)
        XCTAssertEqual(try store.storedInfos(host: "example.com", port: 22).count, 1)
    }

    func testEndpointScopingByHostAndPort() throws {
        try store.trust(keyA, host: "example.com", port: 22)
        try store.trust(keyB, host: "example.com", port: 2222)
        XCTAssertEqual(try store.storedInfos(host: "example.com", port: 22), [keyA])
        XCTAssertEqual(try store.storedInfos(host: "example.com", port: 2222), [keyB])
        XCTAssertFalse(try store.contains(host: "other.com", port: 22))
    }

    func testReplaceSwapsKey() throws {
        try store.trust(keyA, host: "example.com", port: 22)
        try store.replace(with: keyB, host: "example.com", port: 22)
        XCTAssertEqual(try store.storedInfos(host: "example.com", port: 22), [keyB])
    }

    func testRemoveClearsEndpointOnly() throws {
        try store.trust(keyA, host: "a.com", port: 22)
        try store.trust(keyB, host: "b.com", port: 22)
        try store.remove(host: "a.com", port: 22)
        XCTAssertFalse(try store.contains(host: "a.com", port: 22))
        XCTAssertTrue(try store.contains(host: "b.com", port: 22))
    }

    func testReadsCRLFFile() throws {
        // Ferry writes LF, but the file is user-editable — a Windows-touched
        // copy has CRLF, which Swift folds into one Character; a split on "\n"
        // would see it as a single line and trust nothing.
        let line = "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINPThizqWf0Z6Lvo9v8G5cPHYG667J3hD7XRkVP/e4k/"
        try Data("\(line)\r\n".utf8).write(to: fileURL)
        XCTAssertTrue(try store.contains(host: "example.com", port: 22))
        XCTAssertEqual(try store.trustedKeys(host: "example.com", port: 22).count, 1)
    }

    func testNonDefaultPortUsesBracketSpec() throws {
        try store.trust(keyA, host: "example.com", port: 2222)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("[example.com]:2222 ssh-ed25519 "), text)
    }
}
