import Crypto
import Foundation

/// A server's TLS certificate, in the forms the FTPS cert-trust prompt and the
/// CertificateTrustStore need (DOMAIN.md → FTP/FTPS, ADR-033). The analog of
/// `HostKeyInfo` for the SSH host-key TOFU flow: a human-readable subject/issuer
/// summary, the certificate's validity window, and the **SHA-256 of the DER**
/// — the stable identity Ferry shows the user, stores, and pins on every later
/// connect. A value type, safe to hand across the actor boundary and into
/// SwiftUI.
///
/// The fingerprint is over the whole DER (not the public key alone), exactly as
/// `openssl x509 -fingerprint -sha256` reports it, so a re-issued certificate —
/// even with the same key — reads as *changed* and re-prompts, mirroring how
/// SSH fingerprints the whole host key. A certificate is public information, not
/// a secret (rule 6): it belongs in the plaintext trust store; only cert private
/// material would be sensitive, and Ferry never sees that.
public struct CertificateInfo: Sendable, Equatable, Hashable, Identifiable, Codable {
    /// Subject distinguished-name summary, e.g. "CN = ftp.example.com".
    public let subjectSummary: String
    /// Issuer distinguished-name summary (equals the subject for a self-signed
    /// certificate).
    public let issuerSummary: String
    /// SHA-256 over the certificate's DER, as lowercase hex with no separators
    /// (64 chars) — the canonical storage/comparison form and the pin.
    public let sha256: String
    /// Not-before, as libcurl renders it, e.g. "Jul 17 21:22:11 2026 GMT".
    /// A display string; Ferry does not enforce validity (a self-signed cert the
    /// user chose to trust is trusted regardless of its dates), it only shows it.
    public let notBefore: String
    /// Not-after, same rendering.
    public let notAfter: String

    public var id: String { sha256 }

    public init(subjectSummary: String, issuerSummary: String, sha256: String,
                notBefore: String, notAfter: String) {
        self.subjectSummary = subjectSummary
        self.issuerSummary = issuerSummary
        self.sha256 = sha256
        self.notBefore = notBefore
        self.notAfter = notAfter
    }

    /// The fingerprint as shown in the prompt and management UI: uppercase hex
    /// in colon-separated byte pairs (the openssl / browser convention), e.g.
    /// "E1:E5:43:02:…".
    public var displayFingerprint: String {
        var pairs: [String] = []
        var index = sha256.startIndex
        while index < sha256.endIndex {
            let next = sha256.index(index, offsetBy: 2, limitedBy: sha256.endIndex) ?? sha256.endIndex
            pairs.append(String(sha256[index..<next]).uppercased())
            index = next
        }
        return pairs.joined(separator: ":")
    }

    /// The label rendered in the fingerprint box: "SHA-256 · E1:E5:…".
    public var displayFingerprintLabel: String { "SHA-256 · \(displayFingerprint)" }

    /// Builds from libcurl's `CURLINFO_CERTINFO` leaf-certificate fields — each
    /// element is one `"Key:Value"` line as libcurl emits them (the `Cert:` line
    /// carries the multi-line PEM). Returns nil if no parseable certificate PEM
    /// is present. Pure and self-contained so it can be unit-tested against a
    /// captured fixture without a live server.
    public static func from(certinfoFields fields: [String]) -> CertificateInfo? {
        var subject = "", issuer = "", notBefore = "", notAfter = "", pem = ""
        for field in fields {
            if let value = value(of: field, prefix: "Subject:") { subject = value }
            else if let value = value(of: field, prefix: "Issuer:") { issuer = value }
            else if let value = value(of: field, prefix: "Start date:") { notBefore = value }
            else if let value = value(of: field, prefix: "Expire date:") { notAfter = value }
            else if let value = value(of: field, prefix: "Cert:") { pem = value }
        }
        guard let der = derFromPEM(pem) else { return nil }
        return CertificateInfo(subjectSummary: subject.isEmpty ? "—" : subject,
                               issuerSummary: issuer.isEmpty ? "—" : issuer,
                               sha256: sha256Hex(of: der),
                               notBefore: notBefore, notAfter: notAfter)
    }

    /// SHA-256 of DER bytes as lowercase hex — the canonical pin/identity.
    public static func sha256Hex(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private static func value(of field: String, prefix: String) -> String? {
        guard field.hasPrefix(prefix) else { return nil }
        return String(field.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes a PEM certificate block to DER: keep the base64 between the
    /// BEGIN/END markers and decode it. Tolerates surrounding whitespace and
    /// works whether or not the markers are present (a bare base64 body decodes
    /// too).
    static func derFromPEM(_ pem: String) -> Data? {
        let body = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty, let der = Data(base64Encoded: body), !der.isEmpty else { return nil }
        return der
    }
}
