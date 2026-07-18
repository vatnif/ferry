import XCTest
@testable import FerryCore

/// M13 integration tests: SCPSource against the exec-capable Docker SSH server
/// (testinfra/ssh-exec on 127.0.0.1:2223; writable home /home/ferry, read-only
/// fixtures at /home/ferry/fixtures — docs/TESTING.md, ADR-020). Metadata runs
/// as POSIX commands over exec; bytes stream over the classic scp protocol.
@available(macOS 15.0, *)
final class SCPSourceTests: XCTestCase {
    private var source: SCPSource!
    private var workDir: String!

    override func setUp() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.scpPort, serverName: "SSH/SCP")
        source = try await TestServers.connectSCP()
        workDir = "\(TestServers.sshHome)/scp-tests-\(UUID().uuidString.prefix(8))"
        try await source.createDirectory(at: workDir)
    }

    override func tearDown() async throws {
        if let source, let workDir { try? await source.delete(at: workDir) }
        await source?.disconnect()
        source = nil
    }

    /// Byte-exact copy of a seeded fixture, read from the repo working copy.
    private func localSeed(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FerryIntegrationTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // FerryKit
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("testinfra/fixtures/seed/\(name)")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("\(name) not generated yet — run testinfra/start.sh")
        }
        return data
    }

    private func drain(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var data = Data()
        for try await chunk in stream { data += chunk }
        return data
    }

    private func upload(_ contents: Data, to path: String) async throws {
        let handle = try await source.openWrite(at: path, offset: 0)
        try await handle.write(contents)
        try await handle.close()
    }

    // MARK: Connect / home

    func testConnectAndHomeDirectory() async throws {
        let home = try await source.homeDirectory()
        XCTAssertEqual(home, TestServers.sshHome)
    }

    func testWrongPasswordFailsAsAuthentication() async throws {
        await XCTAssertThrowsErrorAsync(
            try await TestServers.connectSCP(credential: .password("definitely-wrong"))) {
            XCTAssertEqual($0 as? RemoteSourceError, .authenticationFailed)
        }
    }

    /// An SFTP-only server (atmoz/sftp on :2222 forces internal-sftp and has no
    /// scp binary) accepts the SSH login but forbids exec — SCPSource must
    /// detect that at connect and say so clearly rather than fail per-op.
    func testExecBlockedServerReportsClearError() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.sftpPort, serverName: "SFTP")
        let store = TestServers.scratchHostKeyStore()
        func connect() async throws -> SCPSource {
            do {
                return try await SCPSource.connect(host: TestServers.host, port: Int(TestServers.sftpPort),
                                                   username: TestServers.username,
                                                   credential: .password(TestServers.password),
                                                   hostKeyStore: store)
            } catch RemoteSourceError.hostKeyUnknown(let info) {
                try store.trust(info, host: TestServers.host, port: Int(TestServers.sftpPort))
                return try await SCPSource.connect(host: TestServers.host, port: Int(TestServers.sftpPort),
                                                   username: TestServers.username,
                                                   credential: .password(TestServers.password),
                                                   hostKeyStore: store)
            }
        }
        await XCTAssertThrowsErrorAsync(try await connect()) {
            guard case RemoteSourceError.connectionFailed(let detail) = $0 else {
                return XCTFail("expected .connectionFailed, got \($0)")
            }
            XCTAssertTrue(detail.contains("does not allow running commands"),
                          "message should explain the SFTP-only server can't do SCP: \(detail)")
        }
    }

    // MARK: Listing / stat

    func testListHomeHasFixtures() async throws {
        let home = try await source.list(directory: TestServers.sshHome, includeHidden: false)
        let fixtures = try XCTUnwrap(home.first { $0.name == "fixtures" })
        XCTAssertTrue(fixtures.isDirectory)
        XCTAssertEqual(fixtures.path, "\(TestServers.sshHome)/fixtures")
    }

    func testListFixturesReportsMetadata() async throws {
        let items = try await source.list(directory: "\(TestServers.sshHome)/fixtures",
                                          includeHidden: false)
        let hello = try XCTUnwrap(items.first { $0.name == "hello.txt" })
        XCTAssertFalse(hello.isDirectory)
        XCTAssertEqual(hello.size, Int64(try localSeed("hello.txt").count))
        XCTAssertNotNil(hello.permissions)
        XCTAssertNotNil(hello.modifiedAt)
        XCTAssertNotNil(hello.owner)
        XCTAssertTrue(items.contains { $0.name == "medium-1mb.bin" })
    }

    func testStatFileDirectoryAndRoot() async throws {
        let file = try await source.stat(path: "\(TestServers.sshHome)/fixtures/hello.txt")
        XCTAssertEqual(file.name, "hello.txt")
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.size, Int64(try localSeed("hello.txt").count))

        let dir = try await source.stat(path: "\(TestServers.sshHome)/fixtures")
        XCTAssertEqual(dir.name, "fixtures")
        XCTAssertTrue(dir.isDirectory)

        let root = try await source.stat(path: "/")
        XCTAssertTrue(root.isDirectory)
        XCTAssertEqual(root.path, "/")
    }

    func testStatMissingThrowsNotFound() async throws {
        let missing = "\(workDir!)/does-not-exist.txt"
        await XCTAssertThrowsErrorAsync(try await self.source.stat(path: missing)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .notFound(path: missing))
        }
    }

    func testListOnFileThrowsNotADirectory() async throws {
        let file = "\(TestServers.sshHome)/fixtures/hello.txt"
        await XCTAssertThrowsErrorAsync(
            try await self.source.list(directory: file, includeHidden: true)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .notADirectory(path: file))
        }
    }

    // MARK: Download (scp -f)

    func testDownloadWholeFileByteExact() async throws {
        let expected = try localSeed("hello.txt")
        let data = try await drain(source.openRead(at: "\(TestServers.sshHome)/fixtures/hello.txt",
                                                   offset: 0))
        XCTAssertEqual(data, expected)
    }

    func testDownloadMultiChunkByteExact() async throws {
        let expected = try localSeed("medium-1mb.bin")
        let data = try await drain(source.openRead(at: "\(TestServers.sshHome)/fixtures/medium-1mb.bin",
                                                   offset: 0))
        XCTAssertEqual(data.count, expected.count)
        XCTAssertEqual(data, expected, "downloaded bytes must match the seeded file exactly")
    }

    /// SCP has no seek, so resume re-reads from the start — but the stream must
    /// still begin at `offset` so the engine appends correctly.
    func testDownloadFromOffsetSkipsPrefix() async throws {
        let full = try localSeed("hello.txt")
        let offset = 34
        let data = try await drain(source.openRead(at: "\(TestServers.sshHome)/fixtures/hello.txt",
                                                   offset: Int64(offset)))
        XCTAssertEqual(data, full.subdata(in: offset..<full.count))
    }

    func testDownloadMissingThrowsNotFound() async throws {
        let missing = "\(workDir!)/nope.bin"
        await XCTAssertThrowsErrorAsync(
            try await self.drain(self.source.openRead(at: missing, offset: 0))) {
            XCTAssertEqual($0 as? FileSystemSourceError, .notFound(path: missing))
        }
    }

    // MARK: Upload (scp -t) + round-trip

    func testUploadThenDownloadRoundTripByteExact() async throws {
        let payload = Data((0..<600_000).map { UInt8(($0 &* 37) % 256) })
        let remote = "\(workDir!)/roundtrip.bin"
        try await upload(payload, to: remote)

        let stat = try await source.stat(path: remote)
        XCTAssertEqual(stat.size, Int64(payload.count))

        let back = try await drain(source.openRead(at: remote, offset: 0))
        XCTAssertEqual(back, payload)
    }

    /// SCP can't append, so a resume (offset > 0) is rejected — the engine then
    /// restarts the upload cleanly (DOMAIN.md → SCP compromises).
    func testUploadResumeOffsetRejected() async throws {
        await XCTAssertThrowsErrorAsync(
            try await self.source.openWrite(at: "\(self.workDir!)/x.bin", offset: 5)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .invalidOffset(5))
        }
    }

    // MARK: Mutations

    func testCreateDirectoryWithIntermediatesAndDelete() async throws {
        let deep = "\(workDir!)/a/b/c"
        try await source.createDirectory(at: deep)
        let deepStat = try await source.stat(path: deep)
        XCTAssertTrue(deepStat.isDirectory)

        // Re-creating an existing directory is refused (matches other backends).
        await XCTAssertThrowsErrorAsync(try await self.source.createDirectory(at: deep)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .alreadyExists(path: deep))
        }

        // Recursive delete removes the whole subtree.
        try await source.delete(at: "\(workDir!)/a")
        await XCTAssertThrowsErrorAsync(try await self.source.stat(path: "\(self.workDir!)/a")) {
            XCTAssertEqual($0 as? FileSystemSourceError, .notFound(path: "\(self.workDir!)/a"))
        }
    }

    func testRenameMovesFileAndRefusesClobber() async throws {
        let src = "\(workDir!)/rename-src.txt"
        let dst = "\(workDir!)/rename-dst.txt"
        let other = "\(workDir!)/rename-other.txt"
        try await upload(Data("one".utf8), to: src)

        try await source.rename(from: src, to: dst)
        _ = try await source.stat(path: dst)
        await XCTAssertThrowsErrorAsync(try await self.source.stat(path: src)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .notFound(path: src))
        }

        try await upload(Data("two".utf8), to: other)
        await XCTAssertThrowsErrorAsync(try await self.source.rename(from: dst, to: other)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .alreadyExists(path: other))
        }
    }

    func testRenameMissingSourceThrowsNotFound() async throws {
        let missing = "\(workDir!)/missing-src.txt"
        let target = "\(workDir!)/missing-dst.txt"
        await XCTAssertThrowsErrorAsync(try await self.source.rename(from: missing, to: target)) {
            XCTAssertEqual($0 as? FileSystemSourceError, .notFound(path: missing))
        }
    }

    func testSetPermissionsRoundTrip() async throws {
        let path = "\(workDir!)/chmod.txt"
        try await upload(Data("perms".utf8), to: path)

        try await source.setPermissions(FilePermissions(rawMode: 0o600), at: path)
        let locked = try await source.stat(path: path)
        XCTAssertEqual((locked.permissions?.rawMode ?? 0) & 0o777, 0o600)

        try await source.setPermissions(FilePermissions(rawMode: 0o644), at: path)
        let opened = try await source.stat(path: path)
        XCTAssertEqual((opened.permissions?.rawMode ?? 0) & 0o777, 0o644)
    }
}
