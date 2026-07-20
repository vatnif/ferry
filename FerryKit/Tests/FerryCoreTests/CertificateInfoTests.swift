import XCTest
@testable import FerryCore

/// Unit tests for `CertificateInfo` (ADR-033): building from libcurl's
/// `CURLINFO_CERTINFO` field lines, the whole-cert DER SHA-256 fingerprint (the
/// pin/identity), and the display formatting shown in the cert-trust prompt.
///
/// The fixture is the actual self-signed certificate served by the FTPS test
/// container (:2990). Its DER SHA-256, verified independently with
/// `openssl x509 -outform der | openssl dgst -sha256`, is the golden value below.
final class CertificateInfoTests: XCTestCase {
    /// The leaf certificate exactly as libcurl reports it in `CURLINFO_CERTINFO`:
    /// "Key:Value" lines, the `Cert:` line carrying the multi-line PEM.
    private static let certinfoFields: [String] = [
        "Subject:CN = 127.0.0.1",
        "Issuer:CN = 127.0.0.1",
        "Version:0",
        "Start date:Jul 17 21:22:11 2026 GMT",
        "Expire date:Jul 14 21:22:11 2036 GMT",
        "Cert:" + pem,
    ]

    private static let pem = """
    -----BEGIN CERTIFICATE-----
    MIICpDCCAYwCCQCEFHS69kIf3jANBgkqhkiG9w0BAQsFADAUMRIwEAYDVQQDDAkx
    MjcuMC4wLjEwHhcNMjYwNzE3MjEyMjExWhcNMzYwNzE0MjEyMjExWjAUMRIwEAYD
    VQQDDAkxMjcuMC4wLjEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCx
    kVXwfLu/8DEb+d+ImndHGHVN6fkojhNvlsoISJMrDsLv7CohfY+uT+IVjH962+A9
    f+xnxRmKN+dwO5xgcT0lzsETO+XCf29Y14mKyW2RpXZIaDIAE0RUux+5WoWH9ezp
    S0+USeUPQfoY1zMWAcZEmh+bk4Q5+tMo/0nkt1oNBgYsq15ZMScFs24IYGssrkYA
    LVjcd9prQB45esZv8VDPhTm60h6InPbq6GA9h9ncoQAQGulH9cqBH9psB/fBe5Ij
    FrG2caiO3gAXA7VFtz9nLGLQz2NfWzHwe/t3jCZCNssFiVhXyOJ6Gufgca/DQskr
    vYLZu9Q6nI5zNYE//muJAgMBAAEwDQYJKoZIhvcNAQELBQADggEBAFaV+Uqm6qdx
    qU//dJ+TezIzhGX4RpsKzv4vsFO395hpNSm344ijm7BCScnbUMz9Pu7xfQ+KVXBc
    Dbmj6cf4BgE3/UiVrJA2RSvkxAdXj1hAs8/YqmcR1iJp2p9Qt7TSi6FWSL8a1LdO
    d4hn1AZNMIYCZ+Ves1+P3+HZHDs2/A/dsPXqIA7vYJuO/GtZE32lswkfsoS3C7Yc
    h5ZEsoJyKAEoscvN8tMkhn6jFKTIxNUu7qNUpOOmBQksn/Eg1tdY9Tw2oD02dN9n
    cO0grAgAiOQRhdmGaW42afgOf5yPvpkJrpUdx8voI/mlsWfoxDpLzDlHj/gi+6sK
    nTqI/cE858k=
    -----END CERTIFICATE-----
    """

    /// openssl x509 -outform der | openssl dgst -sha256
    private static let goldenSHA256 =
        "e1e54302956a2138fb5cee28f6e8183722ad6861648f917a33e11cc64bec288d"

    func testBuildFromCertinfoFields() throws {
        let info = try XCTUnwrap(CertificateInfo.from(certinfoFields: Self.certinfoFields))
        XCTAssertEqual(info.subjectSummary, "CN = 127.0.0.1")
        XCTAssertEqual(info.issuerSummary, "CN = 127.0.0.1")
        XCTAssertEqual(info.notBefore, "Jul 17 21:22:11 2026 GMT")
        XCTAssertEqual(info.notAfter, "Jul 14 21:22:11 2036 GMT")
        XCTAssertEqual(info.sha256, Self.goldenSHA256)
    }

    func testDisplayFingerprintIsColonHex() throws {
        let info = try XCTUnwrap(CertificateInfo.from(certinfoFields: Self.certinfoFields))
        // Uppercase byte pairs joined by ':', matching openssl's -fingerprint.
        XCTAssertEqual(info.displayFingerprint,
            "E1:E5:43:02:95:6A:21:38:FB:5C:EE:28:F6:E8:18:37:22:AD:68:61:64:8F:91:7A:33:E1:1C:C6:4B:EC:28:8D")
        XCTAssertTrue(info.displayFingerprintLabel.hasPrefix("SHA-256 · "))
        XCTAssertEqual(info.id, info.sha256)
    }

    func testMissingCertificateYieldsNil() {
        XCTAssertNil(CertificateInfo.from(certinfoFields: ["Subject:CN = x", "Issuer:CN = y"]))
    }

    func testDerFromPEMToleratesBareBase64() throws {
        // A raw base64 body (no BEGIN/END markers) still decodes.
        let bare = Self.pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        let der = try XCTUnwrap(CertificateInfo.derFromPEM(bare))
        XCTAssertEqual(CertificateInfo.sha256Hex(of: der), Self.goldenSHA256)
    }

    func testSubjectFallbackWhenAbsent() throws {
        // A cert with no Subject/Issuer lines still builds (fields fall back to "—").
        let info = try XCTUnwrap(CertificateInfo.from(certinfoFields: ["Cert:" + Self.pem]))
        XCTAssertEqual(info.subjectSummary, "—")
        XCTAssertEqual(info.sha256, Self.goldenSHA256)
    }
}
