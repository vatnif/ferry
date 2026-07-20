import XCTest
@testable import FerryCore

/// Exercises Ferry's FTPS certificate trust store on a real temp file (ADR-033):
/// trust round-trip, per-endpoint scoping, first-contact vs changed detection,
/// replace, remove, and the management listing — the operations the cert TOFU
/// flow drives. Mirrors `HostKeyStoreTests`.
final class CertificateTrustStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: CertificateTrustStore!

    private let certA = CertificateInfo(subjectSummary: "CN = a.example.com",
                                        issuerSummary: "CN = Example CA",
                                        sha256: String(repeating: "a", count: 64),
                                        notBefore: "Jan 1 00:00:00 2026 GMT",
                                        notAfter: "Jan 1 00:00:00 2036 GMT")
    private let certB = CertificateInfo(subjectSummary: "CN = b.example.com",
                                        issuerSummary: "CN = b.example.com",
                                        sha256: String(repeating: "b", count: 64),
                                        notBefore: "Feb 2 00:00:00 2026 GMT",
                                        notAfter: "Feb 2 00:00:00 2036 GMT")

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-trusted_certs-\(UUID().uuidString).json")
        store = CertificateTrustStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    func testMissingFileIsEmpty() throws {
        XCTAssertFalse(try store.contains(host: "a.example.com", port: 21))
        XCTAssertNil(try store.trustedCertificate(host: "a.example.com", port: 21))
        XCTAssertEqual(try store.storedInfos(host: "a.example.com", port: 21), [])
        XCTAssertEqual(try store.allTrustedCertificates().count, 0)
    }

    func testTrustRoundTrip() throws {
        try store.trust(certA, host: "a.example.com", port: 990)
        // A fresh store instance reads the same file — trust is persisted.
        let reopened = CertificateTrustStore(fileURL: fileURL)
        XCTAssertTrue(try reopened.contains(host: "a.example.com", port: 990))
        XCTAssertEqual(try reopened.trustedCertificate(host: "a.example.com", port: 990), certA)
        XCTAssertEqual(try reopened.storedInfos(host: "a.example.com", port: 990), [certA])
    }

    func testPerEndpointScoping() throws {
        try store.trust(certA, host: "a.example.com", port: 990)
        // Same host, different port ⇒ a different endpoint (first contact).
        XCTAssertNil(try store.trustedCertificate(host: "a.example.com", port: 21))
        XCTAssertFalse(try store.contains(host: "a.example.com", port: 21))
    }

    func testHostKeyIsCaseInsensitive() throws {
        try store.trust(certA, host: "A.Example.COM", port: 990)
        XCTAssertEqual(try store.trustedCertificate(host: "a.example.com", port: 990), certA)
    }

    func testFirstContactVsChanged() throws {
        // Empty stored ⇒ first contact (TOFU).
        XCTAssertEqual(try store.storedInfos(host: "h", port: 990), [])
        try store.trust(certA, host: "h", port: 990)
        // Non-empty stored, differing fingerprint ⇒ the app raises "changed".
        let stored = try store.storedInfos(host: "h", port: 990)
        XCTAssertEqual(stored, [certA])
        XCTAssertNotEqual(stored.first?.sha256, certB.sha256)
    }

    func testReplaceOverwrites() throws {
        try store.trust(certA, host: "h", port: 990)
        try store.replace(with: certB, host: "h", port: 990)
        XCTAssertEqual(try store.trustedCertificate(host: "h", port: 990), certB)
        XCTAssertEqual(try store.allTrustedCertificates().count, 1)
    }

    func testRemove() throws {
        try store.trust(certA, host: "h", port: 990)
        try store.remove(host: "h", port: 990)
        XCTAssertFalse(try store.contains(host: "h", port: 990))
    }

    func testAllTrustedCertificates() throws {
        try store.trust(certA, host: "a.example.com", port: 990)
        try store.trust(certB, host: "b.example.com", port: 21)
        let all = try store.allTrustedCertificates()
        XCTAssertEqual(all.count, 2)
        let a = try XCTUnwrap(all.first { $0.host == "a.example.com" })
        XCTAssertEqual(a.port, 990)
        XCTAssertEqual(a.endpoint, "a.example.com:990")
        XCTAssertEqual(a.certificate, certA)
        let b = try XCTUnwrap(all.first { $0.host == "b.example.com" })
        XCTAssertEqual(b.port, 21)
        XCTAssertEqual(b.endpoint, "b.example.com")   // port 21 omitted
    }

    func testParseKey() {
        XCTAssertEqual(CertificateTrustStore.parseKey("host:990")?.host, "host")
        XCTAssertEqual(CertificateTrustStore.parseKey("host:990")?.port, 990)
        // IPv6 literal: split on the last colon.
        XCTAssertEqual(CertificateTrustStore.parseKey("::1:990")?.host, "::1")
        XCTAssertEqual(CertificateTrustStore.parseKey("::1:990")?.port, 990)
        XCTAssertNil(CertificateTrustStore.parseKey("noport"))
        XCTAssertNil(CertificateTrustStore.parseKey(":990"))
    }

    func testCorruptFileStartsClean() throws {
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertEqual(try store.allTrustedCertificates().count, 0)
        // And a subsequent trust decision rewrites it cleanly.
        try store.trust(certA, host: "h", port: 990)
        XCTAssertEqual(try store.trustedCertificate(host: "h", port: 990), certA)
    }
}
