import XCTest
@testable import FerryCore

/// M5 integration tests: LocalFileSource against the real filesystem.
final class LocalFileSourceTests: XCTestCase {
    private var root: URL!
    private let source = LocalFileSource()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-localfs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func path(_ name: String) -> String { root.appendingPathComponent(name).path }

    private func makeFile(_ name: String, _ contents: String = "data") throws -> String {
        let p = path(name)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: p))
        return p
    }

    // MARK: Listing & stat

    func testListReportsFilesDirectoriesAndMetadata() async throws {
        _ = try makeFile("readme.txt", "hello world")
        try FileManager.default.createDirectory(atPath: path("sub"), withIntermediateDirectories: false)

        let items = try await source.list(directory: root.path, includeHidden: false)
        XCTAssertEqual(Set(items.map(\.name)), ["readme.txt", "sub"])

        let file = try XCTUnwrap(items.first { $0.name == "readme.txt" })
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.size, 11)
        XCTAssertNotNil(file.modifiedAt)
        XCTAssertNotNil(file.permissions)
        XCTAssertEqual(file.owner, NSUserName())

        let dir = try XCTUnwrap(items.first { $0.name == "sub" })
        XCTAssertTrue(dir.isDirectory)
        XCTAssertNil(dir.size)
    }

    func testHiddenFilesFilteredUnlessRequested() async throws {
        _ = try makeFile(".env")
        _ = try makeFile("visible.txt")

        let visible = try await source.list(directory: root.path, includeHidden: false)
        XCTAssertEqual(visible.map(\.name), ["visible.txt"])

        let all = try await source.list(directory: root.path, includeHidden: true)
        XCTAssertEqual(Set(all.map(\.name)), [".env", "visible.txt"])
        XCTAssertEqual(all.first { $0.name == ".env" }?.isHidden, true)
    }

    func testListErrors() async throws {
        let missing = path("nope")
        await XCTAssertThrowsErrorAsync(try await source.list(directory: missing, includeHidden: true)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .notFound(path: missing))
        }
        let file = try makeFile("plain.txt")
        await XCTAssertThrowsErrorAsync(try await source.list(directory: file, includeHidden: true)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .notADirectory(path: file))
        }
    }

    func testStatAndSymlinkDetection() async throws {
        let target = try makeFile("target.txt")
        let link = path("alias")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let item = try await source.stat(path: link)
        XCTAssertTrue(item.isSymlink)
        await XCTAssertThrowsErrorAsync(try await source.stat(path: self.path("missing"))) { _ in }
    }

    // MARK: Mutations

    func testCreateDeleteRenameDirectoryTree() async throws {
        let dir = path("a/b/c")
        try await source.createDirectory(at: dir)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue)

        await XCTAssertThrowsErrorAsync(try await source.createDirectory(at: dir)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .alreadyExists(path: dir))
        }

        let renamed = path("a/b/renamed")
        try await source.rename(from: dir, to: renamed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))

        // Recursive delete of a non-empty tree.
        _ = try makeFile("a/b/renamed/file.txt")
        try await source.delete(at: path("a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("a")))
    }

    func testRenameOntoExistingIsRefused() async throws {
        let a = try makeFile("a.txt"), b = try makeFile("b.txt")
        await XCTAssertThrowsErrorAsync(try await source.rename(from: a, to: b)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .alreadyExists(path: b))
        }
    }

    func testSetPermissionsRoundTrip() async throws {
        let file = try makeFile("perms.txt")
        try await source.setPermissions(FilePermissions(rawMode: 0o600), at: file)
        let item = try await source.stat(path: file)
        XCTAssertEqual(item.permissions?.octalString, "600")
        XCTAssertEqual(item.permissions?.symbolic, "rw-------")
    }

    // MARK: Streaming read/write (the transfer + resume seam)

    func testReadStreamsWholeFileAndHonorsOffset() async throws {
        let file = try makeFile("digits.txt", "0123456789")

        var whole = Data()
        for try await chunk in try await source.openRead(at: file, offset: 0) { whole += chunk }
        XCTAssertEqual(String(decoding: whole, as: UTF8.self), "0123456789")

        var tail = Data()
        for try await chunk in try await source.openRead(at: file, offset: 4) { tail += chunk }
        XCTAssertEqual(String(decoding: tail, as: UTF8.self), "456789")
    }

    func testReadLargeFileInChunks() async throws {
        let big = path("big.bin")
        let payload = Data((0..<(LocalFileSource.readChunkSize * 2 + 123)).map { UInt8($0 % 251) })
        try payload.write(to: URL(fileURLWithPath: big))

        var collected = Data()
        var chunks = 0
        for try await chunk in try await source.openRead(at: big, offset: 0) {
            collected += chunk
            chunks += 1
        }
        XCTAssertEqual(collected, payload, "byte-exact round trip")
        XCTAssertGreaterThanOrEqual(chunks, 3)
    }

    func testWriteFreshThenResumeAtOffset() async throws {
        let file = path("out.txt")

        let fresh = try await source.openWrite(at: file, offset: 0)
        try await fresh.write(Data("HelloWorld".utf8))
        try await fresh.close()

        // Resume contract: truncate to offset, then append.
        let resume = try await source.openWrite(at: file, offset: 5)
        try await resume.write(Data("12345".utf8))
        try await resume.close()

        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "Hello12345")
    }

    func testWriteErrors() async throws {
        // Nonzero offset into a nonexistent file makes no sense for resume.
        await XCTAssertThrowsErrorAsync(try await source.openWrite(at: self.path("ghost"), offset: 7)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .invalidOffset(7))
        }
        await XCTAssertThrowsErrorAsync(try await source.openRead(at: self.path("ghost"), offset: 0)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .notFound(path: self.path("ghost")))
        }
    }
}

/// async variant of XCTAssertThrowsError.
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ verify: (Error) -> Void) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        verify(error)
    }
}
