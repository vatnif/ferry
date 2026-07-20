import XCTest
@testable import FerryCore

/// Unit tests for Ferry's own connection export/import format (M20 checkpoint B,
/// ADR-032): round-trip fidelity, versioning/validation, flattening, and the
/// secret-free / sanitized guarantees.
final class ConnectionExportTests: XCTestCase {

    private func profile(_ name: String, host: String = "h.example.com",
                         scheme: TransferProtocol = .sftp) -> ConnectionProfile {
        ConnectionProfile(name: name, scheme: scheme, host: host, username: "me")
    }

    func testRoundTripPreservesStructure() throws {
        let tree: [SidebarItem] = [
            .profile(profile("Top")),
            .folder(ProfileFolder(name: "Work", items: [
                .profile(profile("Server A")),
                .folder(ProfileFolder(name: "EU", items: [.profile(profile("Server B"))])),
            ])),
        ]
        let data = try ConnectionExport.encode(items: tree, generator: "Ferry test")
        let decoded = try ConnectionExport.decode(data)
        XCTAssertEqual(decoded.format, ConnectionExport.formatIdentifier)
        XCTAssertEqual(decoded.formatVersion, ConnectionExport.currentFormatVersion)
        XCTAssertEqual(decoded.generator, "Ferry test")

        // Structure + identity survive. (Full `==` would trip over ISO-8601
        // dropping createdAt/modifiedAt sub-second precision — a serialization
        // detail, not a fidelity loss; re-encoding is idempotent, asserted below.)
        let before = ConnectionExport.flatten(tree)
        let after = ConnectionExport.flatten(decoded.items)
        XCTAssertEqual(after.map { [$0.profile.id.uuidString, $0.profile.name, $0.folderPath.joined(separator: "/")] },
                       before.map { [$0.profile.id.uuidString, $0.profile.name, $0.folderPath.joined(separator: "/")] })
        // A second round trip reproduces the exact same bytes.
        XCTAssertEqual(try ConnectionExport.encode(items: decoded.items, generator: "Ferry test"), data)
    }

    func testFlattenCarriesFolderPaths() throws {
        let tree: [SidebarItem] = [
            .profile(profile("Top")),
            .folder(ProfileFolder(name: "Work", items: [
                .profile(profile("Server A")),
                .folder(ProfileFolder(name: "EU", items: [.profile(profile("Server B"))])),
            ])),
        ]
        let entries = ConnectionExport.flatten(tree)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.profile.name, $0.folderPath) })
        XCTAssertEqual(byName["Top"], [])
        XCTAssertEqual(byName["Server A"], ["Work"])
        XCTAssertEqual(byName["Server B"], ["Work", "EU"])
    }

    func testSanitizeStripsRuntimePathsButKeepsSettings() throws {
        var p = profile("S")
        p.lastLocalPath = "/Users/me/Downloads"
        p.lastRemotePath = "/var/www"
        p.localStartPath = "/Users/me/Sites"      // a user setting — must survive
        p.remoteStartPath = "/srv"
        let sanitized = ConnectionExport.sanitized([.profile(p)])
        guard case .profile(let out) = sanitized[0] else { return XCTFail() }
        XCTAssertNil(out.lastLocalPath)
        XCTAssertNil(out.lastRemotePath)
        XCTAssertEqual(out.localStartPath, "/Users/me/Sites")
        XCTAssertEqual(out.remoteStartPath, "/srv")
    }

    func testExportedJSONCarriesNoSecretKeys() throws {
        // The profile model holds no secret fields; assert the serialized text
        // never contains password/passphrase/secret keys (defense in depth).
        var p = profile("S", scheme: .sftp)
        p.authMethod = .publicKey(privateKeyPath: "/Users/me/.ssh/id_ed25519")
        let data = try ConnectionExport.encode(items: [.profile(p)])
        let json = String(decoding: data, as: UTF8.self).lowercased()
        XCTAssertFalse(json.contains("password"))
        XCTAssertFalse(json.contains("passphrase"))
        XCTAssertFalse(json.contains("secret"))
    }

    func testDecodeRejectsNonFerryJSON() {
        let alien = Data(#"{"format":"something.else","formatVersion":1,"items":[]}"#.utf8)
        XCTAssertThrowsError(try ConnectionExport.decode(alien)) {
            XCTAssertEqual($0 as? ConnectionExportError, .notAFerryExport)
        }
    }

    func testDecodeRejectsFutureFormatVersion() throws {
        // Encode normally, then bump the version in the JSON text.
        let data = try ConnectionExport.encode(items: [.profile(profile("S"))])
        let bumped = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 99")
        XCTAssertThrowsError(try ConnectionExport.decode(Data(bumped.utf8))) {
            XCTAssertEqual($0 as? ConnectionExportError,
                           .unsupportedFormatVersion(found: 99, supported: ConnectionExport.currentFormatVersion))
        }
    }

    func testDecodeRejectsGarbage() {
        XCTAssertThrowsError(try ConnectionExport.decode(Data("not json".utf8))) {
            guard case ConnectionExportError.corrupted = $0 else {
                return XCTFail("expected .corrupted, got \($0)")
            }
        }
    }
}
