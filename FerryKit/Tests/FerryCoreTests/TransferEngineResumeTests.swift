import XCTest
@testable import FerryCore

/// M9 engine behavior: `.ferrypart` staging + resume, upload resume, retry
/// policy, pause/resume, stale-partial GC, and lazy directory transfers —
/// all against the InMemoryFileSource fake (see TransferEngineTests.swift).
final class TransferEngineResumeTests: XCTestCase {
    private let payload = Data((0..<80_000).map { UInt8($0 % 251) })

    private func makeEngine(maxAttempts: Int = 3) -> TransferEngine {
        TransferEngine(maxConcurrent: 1, maxAttempts: maxAttempts,
                       retryDelay: .milliseconds(20))
    }

    private func downloadRequest(_ name: String = "a.bin",
                                 from source: InMemoryFileSource,
                                 to destination: InMemoryFileSource,
                                 mode: TransferRequest.Mode = .automatic) -> TransferRequest {
        TransferRequest(direction: .download, mode: mode,
                        source: source, sourcePath: "/src/\(name)",
                        destination: destination, destinationPath: "/dst/\(name)",
                        displayName: name)
    }

    /// Collects every snapshot for `id` until it reaches a phase for which
    /// `until` returns true (default: any finished phase).
    private func snapshots(engine: TransferEngine, id: UUID,
                           timeout: TimeInterval = 10,
                           until: @escaping (TransferSnapshot.Phase) -> Bool = { $0.isFinished })
        async -> [TransferSnapshot] {
        var seen: [TransferSnapshot] = []
        let deadline = Date().addingTimeInterval(timeout)
        for await snapshot in await engine.events() {
            if snapshot.id == id { seen.append(snapshot) }
            if snapshot.id == id, until(snapshot.phase) { break }
            if Date() > deadline { break }
        }
        return seen
    }

    // MARK: Download resume via .ferrypart

    func testDownloadResumesFromExistingPartial() async throws {
        let source = InMemoryFileSource(files: ["/src/a.bin": payload])
        let destination = InMemoryFileSource(files:
            ["/dst/a.bin" + TransferEngine.partialSuffix: payload.prefix(30_000)])
        let engine = makeEngine()

        let request = downloadRequest(from: source, to: destination)
        await engine.enqueue(request)
        let seen = await snapshots(engine: engine, id: request.id)

        XCTAssertEqual(seen.last?.phase, .completed)
        XCTAssertEqual(seen.last?.resumedFromOffset, 30_000, "must resume, not restart")
        XCTAssertEqual(destination.data(at: "/dst/a.bin"), payload, "resumed file must be byte-exact")
        XCTAssertNil(destination.data(at: "/dst/a.bin" + TransferEngine.partialSuffix),
                     "partial must be renamed away on completion")
    }

    func testCompletedDownloadHasNoPartialAndRestartModeIgnoresPartial() async throws {
        let source = InMemoryFileSource(files: ["/src/a.bin": payload])
        // A partial with WRONG content: restart mode must not resume it.
        let destination = InMemoryFileSource(files:
            ["/dst/a.bin" + TransferEngine.partialSuffix: Data(repeating: 0xFF, count: 10_000)])
        let engine = makeEngine()

        let request = downloadRequest(from: source, to: destination, mode: .restart)
        await engine.enqueue(request)
        let seen = await snapshots(engine: engine, id: request.id)

        XCTAssertEqual(seen.last?.phase, .completed)
        XCTAssertNil(seen.compactMap(\.resumedFromOffset).first, "restart must begin at byte 0")
        XCTAssertEqual(destination.data(at: "/dst/a.bin"), payload)
    }

    func testStalePartialIsDiscarded() async throws {
        let source = InMemoryFileSource(files: ["/src/a.bin": payload])
        let partialPath = "/dst/a.bin" + TransferEngine.partialSuffix
        let destination = InMemoryFileSource(files: [partialPath: payload.prefix(30_000)])
        // Older than the 30-day GC window (DOMAIN.md).
        destination.setModificationDate(Date(timeIntervalSinceNow: -31 * 24 * 3600), at: partialPath)
        let engine = makeEngine()

        let request = downloadRequest(from: source, to: destination)
        await engine.enqueue(request)
        let seen = await snapshots(engine: engine, id: request.id)

        XCTAssertEqual(seen.last?.phase, .completed)
        XCTAssertNil(seen.compactMap(\.resumedFromOffset).first,
                     "a stale partial must be discarded, not resumed")
        XCTAssertEqual(destination.data(at: "/dst/a.bin"), payload)
    }

    func testOversizedPartialIsDiscarded() async throws {
        let source = InMemoryFileSource(files: ["/src/a.bin": payload])
        let partialPath = "/dst/a.bin" + TransferEngine.partialSuffix
        // Bigger than the source: cannot be this transfer's partial.
        let destination = InMemoryFileSource(files:
            [partialPath: payload + Data(repeating: 1, count: 5_000)])
        let engine = makeEngine()

        let request = downloadRequest(from: source, to: destination)
        await engine.enqueue(request)
        let seen = await snapshots(engine: engine, id: request.id)

        XCTAssertEqual(seen.last?.phase, .completed)
        XCTAssertNil(seen.compactMap(\.resumedFromOffset).first)
        XCTAssertEqual(destination.data(at: "/dst/a.bin"), payload)
    }

    func testDownloadReplacesExistingDestinationOnFinalize() async throws {
        let source = InMemoryFileSource(files: ["/src/a.bin": payload])
        let destination = InMemoryFileSource(files: ["/dst/a.bin": Data("old".utf8)])
        let engine = makeEngine()

        let request = downloadRequest(from: source, to: destination, mode: .restart)
        await engine.enqueue(request)
        let seen = await snapshots(engine: engine, id: request.id)

        XCTAssertEqual(seen.last?.phase, .completed)
        XCTAssertEqual(destination.data(at: "/dst/a.bin"), payload,
                       "finalize must replace the confirmed-for-replacement destination")
    }

    // MARK: Upload resume

    func testUploadResumesFromSmallerRemoteFile() async throws {
        let source = InMemoryFileSource(files: ["/src/a.bin": payload])
        let destination = InMemoryFileSource(files: ["/dst/a.bin": payload.prefix(25_000)])
        let engine = makeEngine()

        let request = TransferRequest(direction: .upload,
                                      source: source, sourcePath: "/src/a.bin",
                                      destination: destination, destinationPath: "/dst/a.bin",
                                      displayName: "a.bin")
        await engine.enqueue(request)
        let seen = await snapshots(engine: engine, id: request.id)

        XCTAssertEqual(seen.last?.phase, .completed)
        XCTAssertEqual(seen.last?.resumedFromOffset, 25_000)
        XCTAssertEqual(destination.data(at: "/dst/a.bin"), payload)
    }

    func testUploadRestartsWhenRemoteIsLarger() async throws {
        let source = InMemoryFileSource(files: ["/src/a.bin": payload])
        let destination = InMemoryFileSource(files:
            ["/dst/a.bin": payload + Data(repeating: 9, count: 1_000)])
        let engine = makeEngine()

        let request = TransferRequest(direction: .upload,
                                      source: source, sourcePath: "/src/a.bin",
                                      destination: destination, destinationPath: "/dst/a.bin",
                                      displayName: "a.bin")
        await engine.enqueue(request)
        let seen = await snapshots(engine: engine, id: request.id)

        XCTAssertEqual(seen.last?.phase, .completed)
        XCTAssertNil(seen.compactMap(\.resumedFromOffset).first)
        XCTAssertEqual(destination.data(at: "/dst/a.bin"), payload)
    }

    // MARK: Retry policy

    func testTransientFailureRetriesAndSucceeds() async throws {
        let source = InMemoryFileSource(files: ["/src/a.bin": payload])
        source.openReadFailuresRemaining = 2
        let destination = InMemoryFileSource()
        let engine = makeEngine(maxAttempts: 3)

        let request = downloadRequest(from: source, to: destination)
        await engine.enqueue(request)
        let seen = await snapshots(engine: engine, id: request.id)

        XCTAssertEqual(seen.last?.phase, .completed)
        XCTAssertEqual(seen.last?.attempt, 3, "two failures then success = attempt 3")
        XCTAssertEqual(destination.data(at: "/dst/a.bin"), payload)
    }

    func testRetryResumesOwnPartialData() async throws {
        let source = InMemoryFileSource(files: ["/src/a.bin": payload])
        let destination = InMemoryFileSource()
        destination.failNextWriteAfterBytes = 20_000 // attempt 1 dies mid-file
        let engine = makeEngine(maxAttempts: 3)

        let request = downloadRequest(from: source, to: destination)
        await engine.enqueue(request)
        let seen = await snapshots(engine: engine, id: request.id)

        XCTAssertEqual(seen.last?.phase, .completed)
        XCTAssertEqual(destination.data(at: "/dst/a.bin"), payload,
                       "the retried transfer must produce a byte-exact file")
        let resumedOffsets = seen.compactMap(\.resumedFromOffset)
        XCTAssertFalse(resumedOffsets.isEmpty, "attempt 2 must resume attempt 1's partial")
        XCTAssertTrue(resumedOffsets.allSatisfy { $0 > 0 && $0 < Int64(payload.count) })
    }

    func testRetriesExhaustedEndsInFailed() async throws {
        let source = InMemoryFileSource(files: ["/src/a.bin": payload])
        source.openReadFailuresRemaining = 99
        let destination = InMemoryFileSource()
        let engine = makeEngine(maxAttempts: 2)

        let request = downloadRequest(from: source, to: destination)
        await engine.enqueue(request)
        let seen = await snapshots(engine: engine, id: request.id)

        guard case .failed = seen.last?.phase else {
            return XCTFail("expected failed, got \(String(describing: seen.last?.phase))")
        }
        XCTAssertEqual(seen.last?.attempt, 2, "must stop after maxAttempts")
    }

    func testDeterministicFailureDoesNotRetry() async throws {
        let source = InMemoryFileSource() // no such source file → notFound
        let destination = InMemoryFileSource()
        let engine = makeEngine(maxAttempts: 3)

        let request = downloadRequest(from: source, to: destination)
        await engine.enqueue(request)
        let seen = await snapshots(engine: engine, id: request.id)

        guard case .failed = seen.last?.phase else {
            return XCTFail("expected failed, got \(String(describing: seen.last?.phase))")
        }
        XCTAssertEqual(seen.last?.attempt, 1, "notFound is deterministic — no retries")
    }

    func testFailedItemCanBeResumedManually() async throws {
        let source = InMemoryFileSource(files: ["/src/a.bin": payload])
        source.openReadFailuresRemaining = 1
        let destination = InMemoryFileSource()
        let engine = makeEngine(maxAttempts: 1) // fail immediately, no auto-retry

        let request = downloadRequest(from: source, to: destination)
        await engine.enqueue(request)
        let failed = await snapshots(engine: engine, id: request.id)
        guard case .failed = failed.last?.phase else {
            return XCTFail("expected failed, got \(String(describing: failed.last?.phase))")
        }

        await engine.resume(id: request.id)
        let seen = await snapshots(engine: engine, id: request.id)
        XCTAssertEqual(seen.last?.phase, .completed)
        XCTAssertEqual(destination.data(at: "/dst/a.bin"), payload)
    }

    // MARK: Pause / resume

    func testPauseRunningKeepsPartialAndResumeCompletes() async throws {
        let big = Data((0..<40_000).map { UInt8($0 % 199) })
        let source = InMemoryFileSource(files: ["/src/big.bin": big])
        let destination = InMemoryFileSource()
        destination.writeDelayNanoseconds = 60_000_000 // 4 chunks ⇒ ~240 ms
        let engine = makeEngine()

        let request = downloadRequest("big.bin", from: source, to: destination)
        await engine.enqueue(request)

        // Pause once progress is visible.
        for await snapshot in await engine.events() where snapshot.id == request.id {
            if snapshot.bytesTransferred > 0 {
                await engine.pause(id: request.id)
                break
            }
            if snapshot.phase.isFinished {
                return XCTFail("finished before any progress: \(snapshot.phase)")
            }
        }
        let paused = await snapshots(engine: engine, id: request.id,
                                     until: { $0 == .paused })
        XCTAssertEqual(paused.last?.phase, .paused)

        // Let the interrupted task's zombie write settle, then check the partial.
        try await Task.sleep(nanoseconds: 200_000_000)
        let partial = destination.data(at: "/dst/big.bin" + TransferEngine.partialSuffix)
        XCTAssertNotNil(partial, "pause must keep the partial")
        XCTAssertLessThan(partial?.count ?? 0, big.count)
        XCTAssertNil(destination.data(at: "/dst/big.bin"))

        destination.writeDelayNanoseconds = 0
        await engine.resume(id: request.id)
        let seen = await snapshots(engine: engine, id: request.id)
        XCTAssertEqual(seen.last?.phase, .completed)
        XCTAssertEqual(destination.data(at: "/dst/big.bin"), big,
                       "paused+resumed download must be byte-exact")
        if let resumed = seen.compactMap(\.resumedFromOffset).first {
            XCTAssertGreaterThan(resumed, 0)
        } else {
            XCTFail("resume after pause must continue from the partial")
        }
    }

    func testPauseQueuedItemAndResume() async throws {
        let source = InMemoryFileSource(files: ["/src/slow.bin": payload,
                                                "/src/waiting.bin": payload])
        let destination = InMemoryFileSource()
        destination.writeDelayNanoseconds = 40_000_000
        let engine = makeEngine() // maxConcurrent 1 → second item stays queued

        let running = downloadRequest("slow.bin", from: source, to: destination)
        let queued = downloadRequest("waiting.bin", from: source, to: destination)
        await engine.enqueue(running)
        await engine.enqueue(queued)
        await engine.pause(id: queued.id)

        let pausedState = await snapshots(engine: engine, id: queued.id,
                                          until: { $0 == .paused })
        XCTAssertEqual(pausedState.last?.phase, .paused)

        destination.writeDelayNanoseconds = 0
        await engine.resume(id: queued.id)
        let seen = await snapshots(engine: engine, id: queued.id)
        XCTAssertEqual(seen.last?.phase, .completed)
        XCTAssertEqual(destination.data(at: "/dst/waiting.bin"), payload)
    }

    func testCancelPausedItem() async throws {
        let source = InMemoryFileSource(files: ["/src/slow.bin": payload,
                                                "/src/waiting.bin": payload])
        let destination = InMemoryFileSource()
        destination.writeDelayNanoseconds = 40_000_000
        let engine = makeEngine()

        let running = downloadRequest("slow.bin", from: source, to: destination)
        let queued = downloadRequest("waiting.bin", from: source, to: destination)
        await engine.enqueue(running)
        await engine.enqueue(queued)
        await engine.pause(id: queued.id)
        await engine.cancel(id: queued.id)

        let seen = await snapshots(engine: engine, id: queued.id)
        XCTAssertEqual(seen.last?.phase, .cancelled)
        // Cancelled stays terminal: resume must not revive it.
        await engine.resume(id: queued.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(destination.data(at: "/dst/waiting.bin"))
    }

    // MARK: Directory transfers (lazy enumeration)

    func testDirectoryTransferCopiesTreeLazily() async throws {
        let fileA = Data("alpha".utf8)
        let fileB = Data("bravo-bravo".utf8)
        let fileC = Data("charlie".utf8)
        let source = InMemoryFileSource(
            files: ["/src/folder/a.txt": fileA,
                    "/src/folder/sub/b.txt": fileB,
                    "/src/folder/sub/deeper/c.txt": fileC],
            directories: ["/src", "/src/folder", "/src/folder/sub", "/src/folder/sub/deeper"])
        let destination = InMemoryFileSource(directories: ["/dst"])
        let engine = makeEngine()

        let request = TransferRequest(direction: .upload, kind: .directory,
                                      source: source, sourcePath: "/src/folder",
                                      destination: destination, destinationPath: "/dst/folder",
                                      displayName: "folder")
        await engine.enqueue(request)

        // The tree is 6 items (3 dirs + 3 files), enqueued lazily as each
        // directory runs — wait until all are finished.
        var finishedNames = Set<String>()
        let expected: Set<String> = ["folder", "a.txt", "sub", "b.txt", "deeper", "c.txt"]
        let deadline = Date().addingTimeInterval(10)
        for await snapshot in await engine.events() {
            if snapshot.phase == .completed { finishedNames.insert(snapshot.displayName) }
            if case .failed(let message) = snapshot.phase {
                return XCTFail("\(snapshot.displayName) failed: \(message)")
            }
            if finishedNames == expected || Date() > deadline { break }
        }

        XCTAssertEqual(finishedNames, expected)
        XCTAssertTrue(destination.hasDirectory("/dst/folder"))
        XCTAssertTrue(destination.hasDirectory("/dst/folder/sub"))
        XCTAssertTrue(destination.hasDirectory("/dst/folder/sub/deeper"))
        XCTAssertEqual(destination.data(at: "/dst/folder/a.txt"), fileA)
        XCTAssertEqual(destination.data(at: "/dst/folder/sub/b.txt"), fileB)
        XCTAssertEqual(destination.data(at: "/dst/folder/sub/deeper/c.txt"), fileC)
    }

    func testDirectoryTransferMergesIntoExistingDestination() async throws {
        let fileA = Data("new-content".utf8)
        let source = InMemoryFileSource(
            files: ["/src/folder/a.txt": fileA],
            directories: ["/src", "/src/folder"])
        let destination = InMemoryFileSource(
            files: ["/dst/folder/keep.txt": Data("keep".utf8),
                    "/dst/folder/a.txt": Data("old".utf8)],
            directories: ["/dst", "/dst/folder"])
        let engine = makeEngine()

        let request = TransferRequest(direction: .upload, kind: .directory, mode: .restart,
                                      source: source, sourcePath: "/src/folder",
                                      destination: destination, destinationPath: "/dst/folder",
                                      displayName: "folder")
        await engine.enqueue(request)

        var finishedNames = Set<String>()
        let deadline = Date().addingTimeInterval(10)
        for await snapshot in await engine.events() {
            if snapshot.phase == .completed { finishedNames.insert(snapshot.displayName) }
            if finishedNames == ["folder", "a.txt"] || Date() > deadline { break }
        }

        XCTAssertEqual(destination.data(at: "/dst/folder/a.txt"), fileA,
                       "same-named child must be overwritten (restart mode)")
        XCTAssertEqual(destination.data(at: "/dst/folder/keep.txt"), Data("keep".utf8),
                       "unrelated existing children must survive a merge")
    }
}
