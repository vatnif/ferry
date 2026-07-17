import XCTest
@testable import FerryCore

/// M12 integration tests: real transfers through the TransferEngine between
/// the local filesystem and the Docker FTP server. The engine is
/// protocol-agnostic (proven with SFTP + in-memory sources); these confirm
/// FTPSource satisfies the same contract, including under the engine's
/// concurrency (each op drives its own libcurl handle + control connection —
/// the FTP-specific risk, ADR-019).
final class FTPTransferTests: XCTestCase {
    private var source: FTPSource!
    private var localDir: URL!
    private var remoteDir: String!
    private let local = LocalFileSource()

    override func setUp() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.ftpPort, serverName: "FTP")
        source = try await TestServers.connectFTP()
        localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-ftp-transfers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        remoteDir = "\(TestServers.ftpHome)/xfer-\(UUID().uuidString.prefix(8))"
        try await source.createDirectory(at: remoteDir)
    }

    override func tearDown() async throws {
        if let source, let remoteDir { try? await source.delete(at: remoteDir) }
        await source?.disconnect()
        source = nil
        try? FileManager.default.removeItem(at: localDir)
    }

    private func waitForFinish(engine: TransferEngine, id: UUID,
                               timeout: TimeInterval = 60) async -> TransferSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        for await snapshot in await engine.events() {
            if snapshot.id == id, snapshot.phase.isFinished { return snapshot }
            if Date() > deadline { return nil }
        }
        return nil
    }

    func testUploadThenDownloadRoundTripByteExact() async throws {
        let payload = Data((0..<600_000).map { UInt8(($0 &* 31) % 256) })
        let localFile = localDir.appendingPathComponent("roundtrip.bin")
        try payload.write(to: localFile)
        let remotePath = "\(remoteDir!)/roundtrip.bin"
        let engine = TransferEngine(maxConcurrent: 2)

        let upload = TransferRequest(direction: .upload,
                                     source: local, sourcePath: localFile.path,
                                     destination: source, destinationPath: remotePath,
                                     displayName: "roundtrip.bin")
        await engine.enqueue(upload)
        let uploadResult = await waitForFinish(engine: engine, id: upload.id)
        XCTAssertEqual(uploadResult?.phase, .completed)
        let remoteStat = try await source.stat(path: remotePath)
        XCTAssertEqual(remoteStat.size, Int64(payload.count))

        let downloadedFile = localDir.appendingPathComponent("downloaded.bin")
        let download = TransferRequest(direction: .download,
                                       source: source, sourcePath: remotePath,
                                       destination: local, destinationPath: downloadedFile.path,
                                       displayName: "downloaded.bin")
        await engine.enqueue(download)
        let downloadResult = await waitForFinish(engine: engine, id: download.id)
        XCTAssertEqual(downloadResult?.phase, .completed)
        XCTAssertEqual(try Data(contentsOf: downloadedFile), payload,
                       "upload → download round trip must be byte-exact")
    }

    func testConcurrentUploadsAllComplete() async throws {
        let engine = TransferEngine(maxConcurrent: 3)
        var ids: [UUID: String] = [:]
        var payloads: [String: Data] = [:]

        for index in 0..<5 {
            let name = "multi-\(index).bin"
            let payload = Data((0..<80_000).map { UInt8(($0 &+ index) % 256) })
            payloads[name] = payload
            let localFile = localDir.appendingPathComponent(name)
            try payload.write(to: localFile)
            let request = TransferRequest(direction: .upload,
                                          source: local, sourcePath: localFile.path,
                                          destination: source,
                                          destinationPath: "\(remoteDir!)/\(name)",
                                          displayName: name)
            ids[request.id] = name
            await engine.enqueue(request)
        }

        var finished: [UUID: TransferSnapshot] = [:]
        let deadline = Date().addingTimeInterval(90)
        for await snapshot in await engine.events() {
            if ids.keys.contains(snapshot.id), snapshot.phase.isFinished {
                finished[snapshot.id] = snapshot
            }
            if finished.count == ids.count || Date() > deadline { break }
        }

        XCTAssertEqual(finished.count, ids.count)
        XCTAssertTrue(finished.values.allSatisfy { $0.phase == .completed })
        for (_, name) in ids {
            let stat = try await source.stat(path: "\(remoteDir!)/\(name)")
            XCTAssertEqual(stat.size, Int64(payloads[name]!.count), name)
        }
    }
}
