import XCTest
@testable import FerryCore

/// M21 integration tests (ADR-038): the Finder drag-out pipeline —
/// `DragOutPlan` + `TransferGroupTracker` over a real `TransferEngine` against
/// the Docker SFTP server. This is the engine-side truth the promise delegate
/// relies on; the Finder half itself is a manual checklist (TESTING.md).
final class DragOutDownloadTests: XCTestCase {
    private var source: SFTPSource!
    /// Stands in for the Finder drop folder.
    private var dropDir: URL!
    private var remoteDir: String!
    private let local = LocalFileSource()

    override func setUp() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.sftpPort, serverName: "SFTP")
        source = try await TestServers.connectSFTP()
        dropDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-dragout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dropDir, withIntermediateDirectories: true)
        remoteDir = "/upload/dragout-\(UUID().uuidString.prefix(8))"
        try await source.createDirectory(at: remoteDir)
    }

    override func tearDown() async throws {
        try? await source?.delete(at: remoteDir)
        await source?.disconnect()
        source = nil
        // if-let: when setUp skips (server down) dropDir is still nil, and
        // unwrapping the IUO here would crash the whole xctest process.
        if let dropDir { try? FileManager.default.removeItem(at: dropDir) }
    }

    // MARK: Helpers

    private func seedRemoteFile(at path: String, payload: Data) async throws {
        let handle = try await source.openWrite(at: path, offset: 0)
        try await handle.write(payload)
        try await handle.close()
    }

    private func payload(_ count: Int, seed: Int = 0) -> Data {
        Data((0..<count).map { UInt8((($0 &+ seed) &* 31) % 256) })
    }

    /// Stages a drag-out exactly the way `BrowserSession.beginDragOut` does:
    /// open the group BEFORE enqueueing (on the engine directly), root seeded.
    private func stage(_ item: FileItem, to destinationPath: String,
                       engine: TransferEngine, tracker: TransferGroupTracker) async
        -> (plan: DragOutPlan, handle: TransferGroupHandle) {
        let groupID = UUID()
        let destinationExisted = (try? await local.stat(path: destinationPath)) != nil
        let plan = DragOutPlan.make(item: item, destinationPath: destinationPath,
                                    source: source, destination: local,
                                    destinationExisted: destinationExisted, groupID: groupID)
        let handle = await tracker.open(group: groupID, root: plan.request.id)
        await engine.enqueue(plan.request)
        return (plan, handle)
    }

    /// Modelled on SFTPTransferTests.waitForFinish: consumes the group stream
    /// until `.finished`, with a deadline checked on each event.
    private func waitForGroup(_ handle: TransferGroupHandle,
                              timeout: TimeInterval = 120) async -> TransferGroupOutcome? {
        let deadline = Date().addingTimeInterval(timeout)
        for await event in handle.events {
            if case .finished(let outcome) = event { return outcome }
            if Date() > deadline { return nil }
        }
        return nil
    }

    // MARK: Tests

    func testFileDragOutLandsByteExactWithNoPartialLeft() async throws {
        let bytes = payload(600_000)
        let remotePath = "\(remoteDir!)/report.bin"
        try await seedRemoteFile(at: remotePath, payload: bytes)
        let item = try await source.stat(path: remotePath)

        let engine = TransferEngine(maxConcurrent: 2)
        let tracker = TransferGroupTracker(engine: engine)
        let destination = dropDir.appendingPathComponent("report.bin").path
        let (plan, handle) = await stage(item, to: destination,
                                         engine: engine, tracker: tracker)

        let outcome = await waitForGroup(handle)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), bytes,
                       "drag-out must land the file byte-exact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.partialPath),
                       "no .ferrypart may remain after completion")
    }

    func testFolderDragOutLandsEveryFileByteExactAtFinish() async throws {
        // The real-server version of the tracker's invariant test: at the
        // instant `.finished` arrives, every file of the nested tree must
        // already be on disk byte-exact — the engine marks the root directory
        // `.completed` when its children are merely enqueued, and the tracker
        // is what bridges that gap.
        let files = [
            ("top/a.bin", payload(200_000, seed: 1)),
            ("top/sub/b.bin", payload(150_000, seed: 2)),
            ("top/sub/deep/c.bin", payload(100_000, seed: 3)),
        ]
        try await source.createDirectory(at: "\(remoteDir!)/top")
        try await source.createDirectory(at: "\(remoteDir!)/top/sub")
        try await source.createDirectory(at: "\(remoteDir!)/top/sub/deep")
        for (relative, bytes) in files {
            try await seedRemoteFile(at: "\(remoteDir!)/\(relative)", payload: bytes)
        }
        let item = try await source.stat(path: "\(remoteDir!)/top")

        let engine = TransferEngine(maxConcurrent: 3)
        let tracker = TransferGroupTracker(engine: engine)
        let destination = dropDir.appendingPathComponent("top").path
        let (_, handle) = await stage(item, to: destination,
                                      engine: engine, tracker: tracker)

        let deadline = Date().addingTimeInterval(120)
        var finished: TransferGroupOutcome?
        for await event in handle.events {
            if case .finished(let outcome) = event {
                finished = outcome
                // Captured AT the instant of `.finished`, before anything else
                // can run — this is the promise-signalling moment.
                for (relative, bytes) in files {
                    let landed = dropDir.appendingPathComponent(relative)
                    XCTAssertEqual(try? Data(contentsOf: landed), bytes,
                                   "\(relative) must be on disk byte-exact when the group finishes")
                }
                break
            }
            if Date() > deadline { break }
        }
        XCTAssertEqual(finished, .completed)
    }

    func testCancelMidTransferCleansUpCreatedDirectory() async throws {
        // A folder whose one file is big enough to still be running when the
        // cancel lands. The litter policy then removes the directory the drag
        // created — the drop folder must be empty afterwards.
        let bytes = payload(4_000_000)
        try await source.createDirectory(at: "\(remoteDir!)/big")
        try await seedRemoteFile(at: "\(remoteDir!)/big/huge.bin", payload: bytes)
        let item = try await source.stat(path: "\(remoteDir!)/big")

        let engine = TransferEngine(maxConcurrent: 1)
        let tracker = TransferGroupTracker(engine: engine)
        let destination = dropDir.appendingPathComponent("big").path
        let (plan, handle) = await stage(item, to: destination,
                                         engine: engine, tracker: tracker)

        let deadline = Date().addingTimeInterval(120)
        var outcome: TransferGroupOutcome?
        var cancelled = false
        for await event in handle.events {
            switch event {
            case .progress(let progress):
                // Cancel once real bytes are moving (the file member, not just
                // the root's enumeration).
                if !cancelled, progress.bytesTransferred > 0 {
                    cancelled = true
                    await tracker.cancelGroup(handle.groupID)
                }
            case .finished(let result):
                outcome = result
            case .stalled:
                XCTFail("nothing pauses in this test")
            }
            if outcome != nil || Date() > deadline { break }
        }
        XCTAssertEqual(outcome, .cancelled)

        await plan.cleanUp(after: .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination),
                       "the directory the drag created must be removed on cancel")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dropDir.path), [],
                       "the drop folder must be left empty")
    }

    func testRestartTruncatesPreExistingGarbagePartial() async throws {
        // A fresh, smaller `.ferrypart` from some earlier cancelled drag of a
        // DIFFERENT file: the resume heuristic would append to it. `.restart`
        // (which DragOutPlan always uses) must truncate it away.
        let bytes = payload(600_000, seed: 7)
        let remotePath = "\(remoteDir!)/replace.bin"
        try await seedRemoteFile(at: remotePath, payload: bytes)
        let item = try await source.stat(path: remotePath)

        let destination = dropDir.appendingPathComponent("replace.bin").path
        try payload(100_000, seed: 9)
            .write(to: URL(fileURLWithPath: destination + TransferEngine.partialSuffix))

        let engine = TransferEngine(maxConcurrent: 1)
        let tracker = TransferGroupTracker(engine: engine)
        let (plan, handle) = await stage(item, to: destination,
                                         engine: engine, tracker: tracker)

        let outcome = await waitForGroup(handle)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), bytes,
                       "the garbage partial must have been truncated, not appended to")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.partialPath))
    }

    func testProgressAggregatesMonotonicallyAndTotalCloses() async throws {
        let sizes = [180_000, 120_000]
        try await source.createDirectory(at: "\(remoteDir!)/pair")
        for (index, size) in sizes.enumerated() {
            try await seedRemoteFile(at: "\(remoteDir!)/pair/f\(index).bin",
                                     payload: payload(size, seed: index))
        }
        let item = try await source.stat(path: "\(remoteDir!)/pair")

        let engine = TransferEngine(maxConcurrent: 2)
        let tracker = TransferGroupTracker(engine: engine)
        let destination = dropDir.appendingPathComponent("pair").path
        let (_, handle) = await stage(item, to: destination,
                                      engine: engine, tracker: tracker)

        let expectedTotal = Int64(sizes.reduce(0, +))
        let deadline = Date().addingTimeInterval(120)
        var outcome: TransferGroupOutcome?
        var lastBytes: Int64 = 0
        var sawNilTotal = false
        var closedTotal: Int64?
        for await event in handle.events {
            switch event {
            case .progress(let progress):
                XCTAssertGreaterThanOrEqual(progress.bytesTransferred, lastBytes,
                                            "aggregate bytes must be monotonic")
                lastBytes = progress.bytesTransferred
                if progress.totalBytes == nil {
                    XCTAssertNil(closedTotal, "totalBytes must not reopen to nil once known")
                    sawNilTotal = true
                } else {
                    closedTotal = progress.totalBytes
                    XCTAssertEqual(progress.totalBytes, expectedTotal,
                                   "a closed total must be the exact sum of the file sizes")
                }
            case .finished(let result):
                outcome = result
            case .stalled:
                XCTFail("nothing pauses in this test")
            }
            if outcome != nil || Date() > deadline { break }
        }
        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(sawNilTotal,
                      "the total must start indeterminate while the directory enumerates")
        XCTAssertEqual(closedTotal, expectedTotal)
        XCTAssertEqual(lastBytes, expectedTotal, "every byte must be accounted for")
    }
}
