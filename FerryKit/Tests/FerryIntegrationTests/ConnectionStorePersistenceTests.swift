import XCTest
@testable import FerryCore

/// M2 integration tests: ConnectionStore against the real filesystem
/// (temp directories — no Docker needed for these).
final class ConnectionStorePersistenceTests: XCTestCase {
    private var tempDir: URL!
    private var store: ConnectionStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-tests-\(UUID().uuidString)", isDirectory: true)
        // Deliberately do NOT create tempDir: save() must create intermediates.
        store = ConnectionStore(fileURL: tempDir
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("connections.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sampleLibrary() -> ConnectionLibrary {
        let date = Date(timeIntervalSince1970: 1_750_000_000) // whole-second (ISO8601)
        let profile = ConnectionProfile(
            name: "prod-web-01", scheme: .sftp, host: "203.0.113.14", username: "deploy",
            authMethod: .publicKey(privateKeyPath: "~/.ssh/id_ed25519"),
            remoteStartPath: "/var/www/html", keepAlive: true,
            tunnels: [TunnelConfiguration(kind: .local, listenPort: 5433,
                                          destinationHost: "db.internal", destinationPort: 5432)],
            createdAt: date, modifiedAt: date)
        let ftp = ConnectionProfile(
            name: "acme-legacy", scheme: .ftps, host: "ftp.acme.com", username: "acme",
            createdAt: date, modifiedAt: date)
        return ConnectionLibrary(items: [
            .folder(ProfileFolder(name: "Work", items: [.profile(profile)])),
            .profile(ftp),
        ])
    }

    func testSaveThenLoadRoundTripsExactly() throws {
        let library = sampleLibrary()
        try store.save(library)
        XCTAssertEqual(try store.load(), library)
    }

    func testLoadWithoutFileReturnsEmptyLibrary() throws {
        let library = try store.load()
        XCTAssertEqual(library.items.count, 0)
        XCTAssertEqual(library.schemaVersion, ConnectionLibrary.currentSchemaVersion)
    }

    func testSaveCreatesIntermediateDirectoriesAndOverwrites() throws {
        try store.save(sampleLibrary())
        var second = sampleLibrary()
        second.items.removeLast()
        try store.save(second) // overwrite
        XCTAssertEqual(try store.load().items.count, 1)
    }

    func testCorruptedFileThrowsDecodingError() throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{ not json ]".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertTrue(error is DecodingError, "expected DecodingError, got \(error)")
        }
    }

    func testNewerSchemaVersionIsRefusedWithPreciseError() throws {
        var future = sampleLibrary()
        future.schemaVersion = ConnectionLibrary.currentSchemaVersion + 1
        try store.save(future)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ConnectionStoreError,
                           .unsupportedSchemaVersion(found: ConnectionLibrary.currentSchemaVersion + 1,
                                                     supported: ConnectionLibrary.currentSchemaVersion))
        }
    }

    func testPersistedFileIsHumanReadableStableJSON() throws {
        let library = sampleLibrary()
        try store.save(library)
        let text = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"))
        XCTAssertTrue(text.contains("\"type\" : \"folder\""))
        // Same library twice ⇒ byte-identical file (sortedKeys) — keeps
        // backups/diffs quiet.
        let first = try Data(contentsOf: store.fileURL)
        try store.save(library)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), first)
    }
}
