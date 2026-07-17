import XCTest
@testable import FerryCore

/// M12 integration tests: FTPSource against the real Docker FTP server
/// (delfer/alpine-ftp-server on 127.0.0.1:2121; login dir /ftp/ferry, writable;
/// read-only fixtures at /ftp/ferry/fixtures — docs/TESTING.md).
final class FTPSourceTests: XCTestCase {
    /// Must match testinfra/fixtures/seed/hello.txt exactly.
    private static let helloContents =
        "Hello from Ferry's test fixtures.\n" +
        "This file is seeded read-only into both test servers at fixtures/hello.txt.\n"

    private var source: FTPSource!
    /// A unique writable directory per test, cleaned up in tearDown.
    private var workDir: String!

    override func setUp() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.ftpPort, serverName: "FTP")
        source = try await TestServers.connectFTP()
        workDir = "\(TestServers.ftpHome)/m12-\(UUID().uuidString)"
        try await source.createDirectory(at: workDir)
    }

    override func tearDown() async throws {
        if let source, let workDir { try? await source.delete(at: workDir) }
        await source?.disconnect()
        source = nil
    }

    // MARK: Connect / auth

    func testHomeDirectory() async throws {
        let home = try await source.homeDirectory()
        XCTAssertEqual(home, TestServers.ftpHome)
    }

    func testWrongPasswordFailsAsAuthentication() async throws {
        await XCTAssertThrowsErrorAsync(
            try await FTPSource.connect(host: TestServers.host, port: Int(TestServers.ftpPort),
                                        username: TestServers.username, password: "definitely-wrong",
                                        security: .none)) {
            XCTAssertEqual($0 as? RemoteSourceError, .authenticationFailed)
        }
    }

    // MARK: Listing / stat

    func testListHomeAndFixtures() async throws {
        let home = try await source.list(directory: TestServers.ftpHome, includeHidden: false)
        let fixtures = try XCTUnwrap(home.first { $0.name == "fixtures" })
        XCTAssertTrue(fixtures.isDirectory)

        let entries = try await source.list(directory: "\(TestServers.ftpHome)/fixtures",
                                            includeHidden: false)
        let hello = try XCTUnwrap(entries.first { $0.name == "hello.txt" })
        XCTAssertFalse(hello.isDirectory)
        XCTAssertEqual(hello.size, Int64(Self.helloContents.utf8.count))
        XCTAssertNotNil(hello.permissions)
        XCTAssertNotNil(hello.modifiedAt)
        XCTAssertNotNil(entries.first { $0.name == "medium-1mb.bin" })
    }

    func testStatFileDirectoryAndRoot() async throws {
        let file = try await source.stat(path: "\(TestServers.ftpHome)/fixtures/hello.txt")
        XCTAssertEqual(file.name, "hello.txt")
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.size, Int64(Self.helloContents.utf8.count))

        let dir = try await source.stat(path: "\(TestServers.ftpHome)/fixtures")
        XCTAssertTrue(dir.isDirectory)

        // Root has no parent to list — it is synthesized.
        let root = try await source.stat(path: "/")
        XCTAssertTrue(root.isDirectory)
        XCTAssertEqual(root.path, "/")
    }

    func testStatMissingThrowsNotFound() async throws {
        let missing = "\(workDir!)/nope.txt"
        await XCTAssertThrowsErrorAsync(try await self.source.stat(path: missing)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .notFound(path: missing))
        }
    }

    // MARK: Download

    func testDownloadWholeFile() async throws {
        let data = try await download("\(TestServers.ftpHome)/fixtures/hello.txt", offset: 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), Self.helloContents)
    }

    func testDownloadFromOffsetUsesREST() async throws {
        let offset = 34 // start of the second line
        let data = try await download("\(TestServers.ftpHome)/fixtures/hello.txt", offset: Int64(offset))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), String(Self.helloContents.dropFirst(offset)))
    }

    func testDownloadMultiChunkByteExact() async throws {
        guard let local = seededMedium() else {
            throw XCTSkip("medium-1mb.bin not generated yet — run testinfra/start.sh")
        }
        let remote = try await download("\(TestServers.ftpHome)/fixtures/medium-1mb.bin", offset: 0)
        XCTAssertEqual(remote.count, local.count)
        XCTAssertEqual(remote, local)
    }

    // MARK: Upload (STOR) + resume (APPE)

    func testUploadDownloadRoundTripByteExact() async throws {
        // Larger than the upload handle's 512 KiB high-water mark, so the
        // read-callback backpressure path is exercised.
        let payload = Data((0..<(900 * 1024)).map { UInt8($0 & 0xff) })
        let path = "\(workDir!)/upload.bin"
        try await upload(payload, to: path, offset: 0)

        let roundTrip = try await download(path, offset: 0)
        XCTAssertEqual(roundTrip.count, payload.count)
        XCTAssertEqual(roundTrip, payload)
    }

    func testUploadResumeAppendsFromOffset() async throws {
        let payload = Data((0..<300_000).map { UInt8(($0 * 7) & 0xff) })
        let split = 120_000
        let path = "\(workDir!)/resume.bin"

        // Simulate an interrupted upload: only the first `split` bytes landed.
        try await upload(payload.prefix(split), to: path, offset: 0)
        let partialSize = try await source.stat(path: path).size
        XCTAssertEqual(partialSize, Int64(split))

        // Resume: append the remainder from the offset (server-side APPE).
        try await upload(payload.suffix(from: split), to: path, offset: Int64(split))

        let complete = try await download(path, offset: 0)
        XCTAssertEqual(complete, payload)
    }

    func testUploadResumeWrongOffsetRejected() async throws {
        let path = "\(workDir!)/mismatch.bin"
        try await upload(Data(repeating: 1, count: 100), to: path, offset: 0)
        // Offset must equal the current remote size (FTP can't truncate).
        await XCTAssertThrowsErrorAsync(try await self.source.openWrite(at: path, offset: 50)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .invalidOffset(50))
        }
    }

    // MARK: Directories, rename, chmod

    func testCreateAndDeleteDirectoryWithIntermediates() async throws {
        let nested = "\(workDir!)/a/b/c"
        try await source.createDirectory(at: nested)
        let cIsDir = try await source.stat(path: nested).isDirectory
        let bIsDir = try await source.stat(path: "\(workDir!)/a/b").isDirectory
        XCTAssertTrue(cIsDir)
        XCTAssertTrue(bIsDir)

        // Creating an existing directory is refused (matches the other backends).
        await XCTAssertThrowsErrorAsync(try await self.source.createDirectory(at: nested)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .alreadyExists(path: nested))
        }

        try await source.delete(at: "\(workDir!)/a")
        await XCTAssertThrowsErrorAsync(try await self.source.stat(path: "\(workDir!)/a")) {
            XCTAssertEqual($0 as? FileSystemSourceError, .notFound(path: "\(self.workDir!)/a"))
        }
    }

    func testRenameMovesAndRefusesClobber() async throws {
        let src = "\(workDir!)/rn-src.txt"
        let dst = "\(workDir!)/rn-dst.txt"
        let other = "\(workDir!)/rn-other.txt"
        try await upload(Data("one".utf8), to: src, offset: 0)

        try await source.rename(from: src, to: dst)
        _ = try await source.stat(path: dst)
        await XCTAssertThrowsErrorAsync(try await self.source.stat(path: src)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .notFound(path: src))
        }

        try await upload(Data("two".utf8), to: other, offset: 0)
        await XCTAssertThrowsErrorAsync(try await self.source.rename(from: dst, to: other)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .alreadyExists(path: other))
        }
    }

    func testSetPermissionsRoundTrip() async throws {
        let path = "\(workDir!)/chmod.txt"
        try await upload(Data("x".utf8), to: path, offset: 0)

        try await source.setPermissions(FilePermissions(rawMode: 0o600), at: path)
        let locked = try await source.stat(path: path).permissions?.rawMode ?? 0
        XCTAssertEqual(locked & 0o777, 0o600)

        try await source.setPermissions(FilePermissions(rawMode: 0o644), at: path)
        let opened = try await source.stat(path: path).permissions?.rawMode ?? 0
        XCTAssertEqual(opened & 0o777, 0o644)
    }

    // MARK: Helpers

    private func download(_ path: String, offset: Int64) async throws -> Data {
        var data = Data()
        for try await chunk in try await source.openRead(at: path, offset: offset) { data += chunk }
        return data
    }

    private func upload<S: Sequence>(_ bytes: S, to path: String, offset: Int64) async throws
    where S.Element == UInt8 {
        let handle = try await source.openWrite(at: path, offset: offset)
        // Write in a couple of chunks to exercise the sequential-write path.
        let data = Data(bytes)
        var index = 0
        let chunk = 256 * 1024
        while index < data.count {
            let end = min(index + chunk, data.count)
            try await handle.write(data.subdata(in: index..<end))
            index = end
        }
        if data.isEmpty { try await handle.write(Data()) }
        try await handle.close()
    }

    private func seededMedium() -> Data? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("testinfra/fixtures/seed/medium-1mb.bin")
        return try? Data(contentsOf: url)
    }
}
