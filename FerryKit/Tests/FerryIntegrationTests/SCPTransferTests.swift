import XCTest
@testable import FerryCore

/// M13 integration tests: real transfers through the TransferEngine between the
/// local filesystem and the Docker SSH server over SCP. Confirms SCPSource
/// satisfies the engine's contract — including under the engine's concurrency,
/// where each transfer drives its own SSH exec channel + scp process (ADR-020).
@available(macOS 15.0, *)
final class SCPTransferTests: XCTestCase {
    private var source: SCPSource!
    private var localDir: URL!
    private var remoteDir: String!
    private let local = LocalFileSource()

    override func setUp() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.scpPort, serverName: "SSH/SCP")
        source = try await TestServers.connectSCP()
        localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-scp-transfers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        remoteDir = "\(TestServers.sshHome)/scp-xfer-\(UUID().uuidString.prefix(8))"
        try await source.createDirectory(at: remoteDir)
    }

    override func tearDown() async throws {
        if let source, let remoteDir { try? await source.delete(at: remoteDir) }
        await source?.disconnect()
        source = nil
        if let localDir { try? FileManager.default.removeItem(at: localDir) }
    }

    private func waitForFinish(engine: TransferEngine, id: UUID,
                               timeout: TimeInterval = 90) async -> TransferSnapshot? {
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

    /// Each SCP op opens its own exec channel; this proves several run
    /// concurrently over one SSHClient without corrupting each other.
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
        let deadline = Date().addingTimeInterval(120)
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

    /// A folder upload: the engine enumerates the directory lazily and SCP
    /// creates the remote tree (mkdir -p) + streams each file.
    func testDirectoryUploadCreatesTreeAndFiles() async throws {
        let treeRoot = localDir.appendingPathComponent("tree", isDirectory: true)
        let sub = treeRoot.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: treeRoot.appendingPathComponent("a.txt"))
        try Data("beta".utf8).write(to: sub.appendingPathComponent("b.txt"))

        let engine = TransferEngine(maxConcurrent: 2)
        let request = TransferRequest(direction: .upload, kind: .directory,
                                      source: local, sourcePath: treeRoot.path,
                                      destination: source,
                                      destinationPath: "\(remoteDir!)/tree",
                                      displayName: "tree")
        await engine.enqueue(request)

        // The directory item fans out lazily into child transfers; poll the
        // remote for the deepest expected file rather than guessing queue state.
        let deepFile = "\(remoteDir!)/tree/sub/b.txt"
        var bStat: FileItem?
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if let stat = try? await source.stat(path: deepFile) { bStat = stat; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertEqual(bStat?.size, Int64("beta".utf8.count),
                       "nested file must be uploaded into the created remote tree")
        let aStat = try await source.stat(path: "\(remoteDir!)/tree/a.txt")
        XCTAssertEqual(aStat.size, Int64("alpha".utf8.count))
    }
}
