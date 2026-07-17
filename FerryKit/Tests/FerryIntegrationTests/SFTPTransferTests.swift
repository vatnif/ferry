import XCTest
@testable import FerryCore

/// M8 integration tests: real transfers through the TransferEngine between
/// the local filesystem and the Docker SFTP server, byte-exact.
final class SFTPTransferTests: XCTestCase {
    private var source: SFTPSource!
    private var localDir: URL!
    private var remoteDir: String!
    private let local = LocalFileSource()

    override func setUp() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.sftpPort, serverName: "SFTP")
        source = try await TestServers.connectSFTP()
        localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-transfers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        remoteDir = "/upload/tests-\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() async throws {
        try? await source?.delete(at: remoteDir)
        await source?.disconnect()
        source = nil
        try? FileManager.default.removeItem(at: localDir)
    }

    private func waitForFinish(engine: TransferEngine, id: UUID,
                               timeout: TimeInterval = 30) async -> TransferSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        for await snapshot in await engine.events() {
            if snapshot.id == id, snapshot.phase.isFinished { return snapshot }
            if Date() > deadline { return nil }
        }
        return nil
    }

    func testUploadThenDownloadRoundTripByteExact() async throws {
        // atmoz/sftp needs the parent dir; SFTP mkdir arrives in M10, so
        // upload directly into /upload.
        let payload = Data((0..<600_000).map { UInt8(($0 &* 31) % 256) })
        let localFile = localDir.appendingPathComponent("roundtrip.bin")
        try payload.write(to: localFile)
        let remotePath = "/upload/roundtrip-\(UUID().uuidString.prefix(8)).bin"
        let source = self.source!
        defer { Task { [source] in try? await source.delete(at: remotePath) } }

        let engine = TransferEngine(maxConcurrent: 2)

        // Upload.
        let upload = TransferRequest(direction: .upload,
                                     source: local, sourcePath: localFile.path,
                                     destination: source, destinationPath: remotePath,
                                     displayName: "roundtrip.bin")
        await engine.enqueue(upload)
        let uploadResult = await waitForFinish(engine: engine, id: upload.id)
        XCTAssertEqual(uploadResult?.phase, .completed)
        let remoteStat = try await source.stat(path: remotePath)
        XCTAssertEqual(remoteStat.size, Int64(payload.count))

        // Download back to a different local file.
        let downloadedFile = localDir.appendingPathComponent("downloaded.bin")
        let download = TransferRequest(direction: .download,
                                       source: source, sourcePath: remotePath,
                                       destination: local, destinationPath: downloadedFile.path,
                                       displayName: "downloaded.bin")
        await engine.enqueue(download)
        let downloadResult = await waitForFinish(engine: engine, id: download.id)
        XCTAssertEqual(downloadResult?.phase, .completed)
        XCTAssertEqual(downloadResult?.bytesTransferred, Int64(payload.count))

        XCTAssertEqual(try Data(contentsOf: downloadedFile), payload,
                       "upload → download round trip must be byte-exact")
    }

    func testConcurrentUploadsAllComplete() async throws {
        let engine = TransferEngine(maxConcurrent: 3)
        var ids: [UUID: String] = [:]
        var payloads: [String: Data] = [:]

        for index in 0..<5 {
            let name = "multi-\(UUID().uuidString.prefix(6))-\(index).bin"
            let payload = Data((0..<50_000).map { UInt8(($0 &+ index) % 256) })
            payloads[name] = payload
            let localFile = localDir.appendingPathComponent(name)
            try payload.write(to: localFile)
            let request = TransferRequest(direction: .upload,
                                          source: local, sourcePath: localFile.path,
                                          destination: source,
                                          destinationPath: "/upload/\(name)",
                                          displayName: name)
            ids[request.id] = name
            await engine.enqueue(request)
        }
        let source = self.source!
        defer {
            let names = Array(payloads.keys)
            Task { [source] in
                for name in names { try? await source.delete(at: "/upload/\(name)") }
            }
        }

        var finished: [UUID: TransferSnapshot] = [:]
        let deadline = Date().addingTimeInterval(60)
        for await snapshot in await engine.events() {
            if ids.keys.contains(snapshot.id), snapshot.phase.isFinished {
                finished[snapshot.id] = snapshot
            }
            if finished.count == ids.count || Date() > deadline { break }
        }

        XCTAssertEqual(finished.count, ids.count)
        XCTAssertTrue(finished.values.allSatisfy { $0.phase == .completed })
        for (_, name) in ids {
            let stat = try await source.stat(path: "/upload/\(name)")
            XCTAssertEqual(stat.size, Int64(payloads[name]!.count), name)
        }
    }

    func testCancelMidUploadLeavesPartialWithoutWedging() async throws {
        let payload = Data(repeating: 0xAB, count: 2_000_000) // 2 MB
        let localFile = localDir.appendingPathComponent("cancelme.bin")
        try payload.write(to: localFile)
        let remotePath = "/upload/cancelme-\(UUID().uuidString.prefix(8)).bin"
        let source = self.source!
        defer { Task { [source] in try? await source.delete(at: remotePath) } }

        let engine = TransferEngine(maxConcurrent: 1)
        let request = TransferRequest(direction: .upload,
                                      source: local, sourcePath: localFile.path,
                                      destination: source, destinationPath: remotePath,
                                      displayName: "cancelme.bin")
        await engine.enqueue(request)

        // Cancel as soon as progress is visible — but break on ANY terminal
        // state so an instant failure can't hang the test (learned in M8:
        // this loop once waited forever on a permission error).
        for await snapshot in await engine.events() where snapshot.id == request.id {
            if snapshot.bytesTransferred > 0 {
                await engine.cancel(id: request.id)
                break
            }
            if snapshot.phase.isFinished {
                XCTFail("transfer ended before any progress: \(snapshot.phase)")
                break
            }
        }
        let result = await waitForFinish(engine: engine, id: request.id)
        XCTAssertEqual(result?.phase, .cancelled)

        // Engine is still usable afterwards.
        let smallFile = localDir.appendingPathComponent("after.bin")
        try Data(repeating: 1, count: 100).write(to: smallFile)
        let followUp = TransferRequest(direction: .upload,
                                       source: local, sourcePath: smallFile.path,
                                       destination: source,
                                       destinationPath: "/upload/after-\(UUID().uuidString.prefix(8)).bin",
                                       displayName: "after.bin")
        await engine.enqueue(followUp)
        let followUpResult = await waitForFinish(engine: engine, id: followUp.id)
        XCTAssertEqual(followUpResult?.phase, .completed)
        try? await source.delete(at: followUp.destinationPath)
    }

    func testSFTPWriteResumeContract() async throws {
        // Direct FileSystemSource-level check of the M5 offset contract on
        // the SFTP backend (feeds M9 resume).
        let remotePath = "/upload/resume-\(UUID().uuidString.prefix(8)).txt"
        let source = self.source!
        defer { Task { [source] in try? await source.delete(at: remotePath) } }

        let fresh = try await source.openWrite(at: remotePath, offset: 0)
        try await fresh.write(Data("HelloWorld".utf8))
        try await fresh.close()

        let resume = try await source.openWrite(at: remotePath, offset: 5)
        try await resume.write(Data("12345".utf8))
        try await resume.close()

        var data = Data()
        for try await chunk in try await source.openRead(at: remotePath, offset: 0) { data += chunk }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "Hello12345")

        // Resuming into a missing file is notFound, like LocalFileSource.
        await XCTAssertThrowsErrorAsync(
            try await self.source.openWrite(at: "/upload/ghost-\(UUID().uuidString.prefix(6)).bin", offset: 7)) {
            guard case .notFound = $0 as? FileSystemSourceError else {
                return XCTFail("expected notFound, got \($0)")
            }
        }
    }
}
