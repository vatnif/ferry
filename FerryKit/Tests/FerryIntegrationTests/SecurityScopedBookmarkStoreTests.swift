import XCTest
@testable import FerryCore

/// M5 integration tests for the bookmark store. Bookmark creation/resolution
/// works in unsandboxed processes too, so the mechanics are testable here;
/// the sandbox-enforcement behavior itself is exercised in the App Store
/// build (M17 checklist).
final class SecurityScopedBookmarkStoreTests: XCTestCase {
    private var dir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-bookmarks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("bookmarks.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testGrantPersistsAcrossReload() throws {
        let store = SecurityScopedBookmarkStore(fileURL: storeURL)
        try store.addGrantedFolder(dir)
        XCTAssertEqual(store.grantedPaths, [dir.path])

        let reloaded = SecurityScopedBookmarkStore(fileURL: storeURL)
        XCTAssertEqual(reloaded.grantedPaths, [dir.path])
    }

    func testWithAccessRunsBodyWithAndWithoutGrant() throws {
        let store = SecurityScopedBookmarkStore(fileURL: storeURL)

        // No grant: pass-through.
        let untracked = try store.withAccess(toPathContaining: "/tmp/elsewhere") { "ran" }
        XCTAssertEqual(untracked, "ran")

        // Grant covering a nested path: body still runs and can do real I/O.
        try store.addGrantedFolder(dir)
        let nested = dir.appendingPathComponent("inner/file.txt")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let value: String = try store.withAccess(toPathContaining: nested.path) {
            try Data("ok".utf8).write(to: nested)
            return try String(contentsOf: nested, encoding: .utf8)
        }
        XCTAssertEqual(value, "ok")
    }

    func testRemoveGrant() throws {
        let store = SecurityScopedBookmarkStore(fileURL: storeURL)
        try store.addGrantedFolder(dir)
        try store.removeGrantedFolder(path: dir.path)
        XCTAssertEqual(store.grantedPaths, [])
        XCTAssertEqual(SecurityScopedBookmarkStore(fileURL: storeURL).grantedPaths, [])
    }

    func testLocalFileSourceComposesWithBookmarkStore() async throws {
        let store = SecurityScopedBookmarkStore(fileURL: storeURL)
        try store.addGrantedFolder(dir)
        let source = LocalFileSource(bookmarks: store)

        let filePath = dir.appendingPathComponent("via-source.txt").path
        let handle = try await source.openWrite(at: filePath, offset: 0)
        try await handle.write(Data("through the store".utf8))
        try await handle.close()

        let items = try await source.list(directory: dir.path, includeHidden: true)
        XCTAssertTrue(items.contains { $0.name == "via-source.txt" })
    }
}
