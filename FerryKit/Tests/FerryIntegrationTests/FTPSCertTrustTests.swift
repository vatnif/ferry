import XCTest
@testable import FerryCore

/// Integration tests for the FTPS self-signed / private-CA certificate
/// trust-on-first-use path (ADR-033), exercised against the real self-signed
/// FTPS test container (:2990). These drive the REAL trust path — they do NOT
/// set the `allowInvalidCertificate` test hook — so they cover capture,
/// fingerprinting, pinning, reconnect and mismatch end-to-end over live TLS.
final class FTPSCertTrustTests: XCTestCase {
    /// The self-signed test cert's DER SHA-256 — the golden pin
    /// (`openssl x509 -outform der | openssl dgst -sha256`), matching the
    /// `CertificateInfoTests` unit fixture.
    private static let goldenSHA256 =
        "e1e54302956a2138fb5cee28f6e8183722ad6861648f917a33e11cc64bec288d"

    override func setUp() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.ftpsPort, serverName: "FTPS")
    }

    /// First contact: an untrusted certificate is captured and its fingerprint
    /// matches the certificate the server actually serves.
    func testFirstContactCapturesCertificate() async throws {
        let offered = try await TestServers.captureFTPSCertificate()
        XCTAssertEqual(offered.sha256, Self.goldenSHA256)
        XCTAssertEqual(offered.subjectSummary, "CN = 127.0.0.1")
        XCTAssertFalse(offered.notAfter.isEmpty)
    }

    /// Trusting the captured certificate lets the connection succeed and browse.
    func testTrustThenConnect() async throws {
        let offered = try await TestServers.captureFTPSCertificate()
        let source = try await TestServers.connectFTPS(trusting: offered)
        defer { let s = source; Task { await s.disconnect() } }
        let home = try await source.homeDirectory()
        XCTAssertEqual(home, TestServers.ftpHome)
        // A real listing over the pinned TLS connection.
        let entries = try await source.list(directory: "\(TestServers.ftpHome)/fixtures",
                                            includeHidden: false)
        XCTAssertTrue(entries.contains { $0.name == "hello.txt" })
    }

    /// A pinned connection re-validates on reconnect (the ConnectionSupervisor
    /// path) without re-prompting: `reestablish` re-applies the identical pin and
    /// succeeds, and further operations work. This is the security-critical
    /// invariant — a supervised reconnect never silently downgrades trust.
    func testReconnectPinsWithoutReprompt() async throws {
        let offered = try await TestServers.captureFTPSCertificate()
        let source = try await TestServers.connectFTPS(trusting: offered)
        defer { let s = source; Task { await s.disconnect() } }
        try await source.reestablish()   // must not throw — same cert, same pin
        try await source.ping()
        let home = try await source.homeDirectory()
        XCTAssertEqual(home, TestServers.ftpHome)
    }

    /// A pinned endpoint that offers a DIFFERENT certificate than the pin is
    /// rejected with `.certificateChanged`, carrying both the stored pin and the
    /// (correctly captured) offered certificate for the "was → now" alarm. Here
    /// the pin is a bogus fingerprint, so the server's real cert is the mismatch.
    func testChangedCertificateIsRejected() async throws {
        let bogus = CertificateInfo(subjectSummary: "CN = attacker",
                                    issuerSummary: "CN = attacker",
                                    sha256: String(repeating: "0", count: 64),
                                    notBefore: "Jan 1 00:00:00 2020 GMT",
                                    notAfter: "Jan 1 00:00:00 2030 GMT")
        await XCTAssertThrowsErrorAsync(
            try await TestServers.connectFTPS(trusting: bogus)) { error in
            guard case .certificateChanged(let stored, let offered) = (error as? RemoteSourceError) else {
                return XCTFail("expected .certificateChanged, got \(error)")
            }
            XCTAssertEqual(stored.sha256, bogus.sha256)
            XCTAssertEqual(offered.sha256, Self.goldenSHA256)   // the real server cert
        }
    }
}
