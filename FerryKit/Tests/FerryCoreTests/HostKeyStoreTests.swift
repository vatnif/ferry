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

    func testNonDefaultPortUsesBracketSpec() throws {
        try store.trust(keyA, host: "example.com", port: 2222)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("[example.com]:2222 ssh-ed25519 "), text)
    }
}
