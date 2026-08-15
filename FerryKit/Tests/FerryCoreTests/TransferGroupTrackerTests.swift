import XCTest
@testable import FerryCore

/// M21 checkpoint B: the per-group completion signal behind the Finder
/// drag-out promise. The engine marks a directory `.completed` as soon as its
/// children are *enqueued*; these tests pin that the tracker's `.finished`
/// only fires once every byte has actually landed — plus the three guards:
/// the seeded root (vacuous-truth), explicit `.stalled` for paused members,
/// and frozen conclusions (a resumed failed directory re-enqueues members).
/// Uses the InMemoryFileSource stub from TransferEngineTests.swift.
final class TransferGroupTrackerTests: XCTestCase {

    /// Consumes a group handle's events on a background task so tests can
    /// wait on predicates without hanging on a stream that never emits.
    private final class GroupEventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TransferGroupEvent] = []
        private var task: Task<Void, Never>?

        init(_ handle: TransferGroupHandle) {
            task = Task { [weak self] in
                for await event in handle.events {
                    self?.append(event)
                }
            }
        }

        deinit { task?.cancel() }

        private func append(_ event: TransferGroupEvent) {
            lock.lock(); defer { lock.unlock() }
            storage.append(event)
        }

        var events: [TransferGroupEvent] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        var progressEvents: [TransferGroupProgress] {
            events.compactMap { if case .progress(let progress) = $0 { progress } else { nil } }
        }

        var sawStalled: Bool {
            events.contains { if case .stalled = $0 { true } else { false } }
        }

        var finished: TransferGroupOutcome? {
            for event in events {
                if case .finished(let outcome) = event { return outcome }
            }
            return nil
        }

        var finishedCount: Int {
            events.filter { if case .finished = $0 { true } else { false } }.count
        }
    }

    /// True when `predicate` becomes true before `timeout`. The poll races a
    /// timer task (ADR-014) so a signal that never comes fails fast instead
    /// of hanging the suite on a stream that never emits.
    private func waitUntil(timeout: TimeInterval = 10,
                           _ predicate: @escaping @Sendable () -> Bool) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                while !Task.isCancelled, !predicate() {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                return !Task.isCancelled
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Asserts `predicate` becomes true before `timeout` (XCTAssert
    /// autoclosures cannot await, so the wait happens here).
    private func assertEventually(timeout: TimeInterval = 10, _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ predicate: @escaping @Sendable () -> Bool) async {
        let satisfied = await waitUntil(timeout: timeout, predicate)
        XCTAssertTrue(satisfied, message, file: file, line: line)
    }

    /// Asserts `predicate` stays false for `timeout` (the ADR-014 absence
    /// check: race a timer instead of hanging on a stream that never emits).
    private func assertNever(within timeout: TimeInterval = 0.3, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line,
                             _ predicate: @escaping @Sendable () -> Bool) async {
        let satisfied = await waitUntil(timeout: timeout, predicate)
        XCTAssertFalse(satisfied, message, file: file, line: line)
    }

    /// First engine snapshot matching `predicate`, racing a timer task
    /// (ADR-014). Subscription replays current state, so a snapshot published
    /// before the call is still found.
    private func firstSnapshot(engine: TransferEngine, timeout: TimeInterval = 10,
                               where predicate: @escaping @Sendable (TransferSnapshot) -> Bool)
        async -> TransferSnapshot? {
        await withTaskGroup(of: TransferSnapshot?.self) { group in
            group.addTask {
                for await snapshot in await engine.events() where predicate(snapshot) {
                    return snapshot
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func downloadRequest(name: String, sourcePath: String, destinationPath: String,
                                 kind: TransferRequest.Kind = .file, groupID: UUID?,
                                 source: InMemoryFileSource,
                                 destination: InMemoryFileSource) -> TransferRequest {
        TransferRequest(direction: .download, kind: kind, groupID: groupID,
                        source: source, sourcePath: sourcePath,
                        destination: destination, destinationPath: destinationPath,
                        displayName: name)
    }

    // MARK: 1 — single file

    func testSingleFileGroupEmitsProgressThenCompleted() async throws {
        let payload = Data((0..<100_000).map { UInt8($0 % 256) })
        let source = InMemoryFileSource(files: ["/src/a.bin": payload])
        let destination = InMemoryFileSource()
        let engine = TransferEngine(maxConcurrent: 1)
        let tracker = TransferGroupTracker(engine: engine)

        let group = UUID()
        let request = downloadRequest(name: "a.bin", sourcePath: "/src/a.bin",
                                      destinationPath: "/dst/a.bin", groupID: group,
                                      source: source, destination: destination)
        let log = GroupEventLog(await tracker.open(group: group, root: request.id))
        await engine.enqueue(request)

        await assertEventually { log.finished != nil }
        XCTAssertEqual(log.finished, .completed)
        XCTAssertTrue(log.progressEvents.contains { $0.bytesTransferred > 0 },
                      "must emit intermediate progress before finishing")
        guard case .finished = log.events.last else {
            return XCTFail("finished must be the stream's last event")
        }
        XCTAssertEqual(destination.data(at: "/dst/a.bin"), payload)
    }

    // MARK: 2 — the invariant: finished ⇒ every byte is on disk

    func testFinishedArrivesOnlyAfterEveryByteLands() async throws {
        let a = Data((0..<40_000).map { UInt8($0 % 251) })
        let b = Data((0..<50_000).map { UInt8($0 % 249) })
        let c = Data((0..<60_000).map { UInt8($0 % 247) })
        let source = InMemoryFileSource(
            files: ["/src/top/a.bin": a, "/src/top/sub/b.bin": b, "/src/top/sub/deep/c.bin": c],
            directories: ["/src", "/src/top", "/src/top/sub", "/src/top/sub/deep"])
        let destination = InMemoryFileSource()
        destination.writeDelayNanoseconds = 10_000_000
        let engine = TransferEngine(maxConcurrent: 2)
        let tracker = TransferGroupTracker(engine: engine)

        let group = UUID()
        let root = downloadRequest(name: "top", sourcePath: "/src/top",
                                   destinationPath: "/dst/top", kind: .directory,
                                   groupID: group, source: source, destination: destination)
        let handle = await tracker.open(group: group, root: root.id)
        await engine.enqueue(root)

        // Capture the destination the instant .finished is observed — the
        // whole point of the tracker is that this can never be too early.
        typealias Capture = (outcome: TransferGroupOutcome, files: [String: Data?])
        let capture: Capture? = await withTaskGroup(of: Capture?.self) { group in
            group.addTask {
                for await event in handle.events {
                    if case .finished(let outcome) = event {
                        return (outcome, [
                            "/dst/top/a.bin": destination.data(at: "/dst/top/a.bin"),
                            "/dst/top/sub/b.bin": destination.data(at: "/dst/top/sub/b.bin"),
                            "/dst/top/sub/deep/c.bin": destination.data(at: "/dst/top/sub/deep/c.bin"),
                        ])
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        XCTAssertEqual(capture?.outcome, .completed)
        XCTAssertEqual(capture?.files["/dst/top/a.bin"], a)
        XCTAssertEqual(capture?.files["/dst/top/sub/b.bin"], b)
        XCTAssertEqual(capture?.files["/dst/top/sub/deep/c.bin"], c)
        XCTAssertTrue(destination.hasDirectory("/dst/top/sub/deep"))
    }

    // MARK: 3 — the root completes long before the group does

    func testRootDirectoryCompletesBeforeGroupFinishes() async throws {
        let payload = Data(repeating: 6, count: 40_000)
        let source = InMemoryFileSource(
            files: ["/src/top/a.bin": payload, "/src/top/b.bin": payload],
            directories: ["/src", "/src/top"])
        let destination = InMemoryFileSource()
        destination.writeDelayNanoseconds = 30_000_000
        let engine = TransferEngine(maxConcurrent: 1)
        let tracker = TransferGroupTracker(engine: engine)

        let group = UUID()
        let root = downloadRequest(name: "top", sourcePath: "/src/top",
                                   destinationPath: "/dst/top", kind: .directory,
                                   groupID: group, source: source, destination: destination)
        let log = GroupEventLog(await tracker.open(group: group, root: root.id))
        await engine.enqueue(root)

        let rootDone = await firstSnapshot(engine: engine) {
            $0.id == root.id && $0.phase == .completed
        }
        XCTAssertNotNil(rootDone, "root directory must complete on enqueueing its children")
        // At this instant the children are still transferring (slow writes),
        // so the group must not have finished — the early-completion trap.
        XCTAssertNil(log.finished,
                     "group must not finish when only the root directory has")
        XCTAssertNil(destination.data(at: "/dst/top/b.bin"))

        await assertEventually { log.finished != nil }
        XCTAssertEqual(log.finished, .completed)
        XCTAssertEqual(destination.data(at: "/dst/top/b.bin"), payload)
    }

    // MARK: 4 — failed member

    func testFailedChildConcludesGroupFailed() async throws {
        let payload = Data(repeating: 3, count: 8_000)
        let source = InMemoryFileSource(
            files: ["/src/top/a.bin": payload, "/src/top/b.bin": payload],
            directories: ["/src", "/src/top"])
        source.openReadFailuresRemaining = 1
        let destination = InMemoryFileSource()
        let engine = TransferEngine(maxConcurrent: 1, maxAttempts: 1)
        let tracker = TransferGroupTracker(engine: engine)

        let group = UUID()
        let root = downloadRequest(name: "top", sourcePath: "/src/top",
                                   destinationPath: "/dst/top", kind: .directory,
                                   groupID: group, source: source, destination: destination)
        let log = GroupEventLog(await tracker.open(group: group, root: root.id))
        await engine.enqueue(root)

        await assertEventually { log.finished != nil }
        guard case .failed(let message)? = log.finished else {
            return XCTFail("expected .failed, got \(String(describing: log.finished))")
        }
        XCTAssertTrue(message.contains("injected read failure"), message)
    }

    // MARK: 5 — cancelled member

    func testCancelledMemberConcludesGroupCancelled() async throws {
        let payload = Data(repeating: 9, count: 40_000)
        let source = InMemoryFileSource(
            files: ["/src/top/a.bin": payload, "/src/top/b.bin": payload],
            directories: ["/src", "/src/top"])
        let destination = InMemoryFileSource()
        destination.writeDelayNanoseconds = 30_000_000
        let engine = TransferEngine(maxConcurrent: 1)
        let tracker = TransferGroupTracker(engine: engine)

        let group = UUID()
        let root = downloadRequest(name: "top", sourcePath: "/src/top",
                                   destinationPath: "/dst/top", kind: .directory,
                                   groupID: group, source: source, destination: destination)
        let log = GroupEventLog(await tracker.open(group: group, root: root.id))
        await engine.enqueue(root)

        // b.bin queues behind a.bin (cap 1, slow writes) — cancel it there.
        let queuedB = await firstSnapshot(engine: engine) {
            $0.groupID == group && $0.displayName == "b.bin"
        }
        let bID = try XCTUnwrap(queuedB).id
        await engine.cancel(id: bID)

        await assertEventually { log.finished != nil }
        XCTAssertEqual(log.finished, .cancelled,
                       "one cancelled member (and no failures) concludes the group cancelled")
        XCTAssertEqual(destination.data(at: "/dst/top/a.bin"), payload,
                       "the untouched member still completes")
    }

    func testCancelGroupCancelsEveryMember() async throws {
        let payload = Data(repeating: 5, count: 40_000)
        let source = InMemoryFileSource(
            files: ["/src/top/a.bin": payload, "/src/top/b.bin": payload,
                    "/src/top/c.bin": payload],
            directories: ["/src", "/src/top"])
        let destination = InMemoryFileSource()
        destination.writeDelayNanoseconds = 30_000_000
        let engine = TransferEngine(maxConcurrent: 1)
        let tracker = TransferGroupTracker(engine: engine)

        let group = UUID()
        let root = downloadRequest(name: "top", sourcePath: "/src/top",
                                   destinationPath: "/dst/top", kind: .directory,
                                   groupID: group, source: source, destination: destination)
        let log = GroupEventLog(await tracker.open(group: group, root: root.id))
        await engine.enqueue(root)

        await assertEventually { log.progressEvents.contains { $0.bytesTransferred > 0 } }
        await tracker.cancelGroup(group)

        await assertEventually { log.finished != nil }
        XCTAssertEqual(log.finished, .cancelled)
        XCTAssertNil(destination.data(at: "/dst/top/c.bin"),
                     "queued members must be cancelled, not run to completion")
    }

    // MARK: 6 — paused member stalls the group

    func testPausedMemberStallsThenResumeCompletes() async throws {
        let payload = Data(repeating: 8, count: 40_000)
        let source = InMemoryFileSource(files: ["/src/a.bin": payload])
        let destination = InMemoryFileSource()
        destination.writeDelayNanoseconds = 60_000_000 // 4 chunks ⇒ ~240 ms
        let engine = TransferEngine(maxConcurrent: 1)
        let tracker = TransferGroupTracker(engine: engine)

        let group = UUID()
        let request = downloadRequest(name: "a.bin", sourcePath: "/src/a.bin",
                                      destinationPath: "/dst/a.bin", groupID: group,
                                      source: source, destination: destination)
        let log = GroupEventLog(await tracker.open(group: group, root: request.id))
        await engine.enqueue(request)
        try await Task.sleep(nanoseconds: 90_000_000) // let ~1-2 chunks through
        await engine.pause(id: request.id)

        await assertEventually { log.sawStalled }
        await assertNever("a paused member must hold the group open, not finish it") {
            log.finished != nil
        }

        await engine.resume(id: request.id)
        await assertEventually { log.finished != nil }
        XCTAssertEqual(log.finished, .completed)
        XCTAssertEqual(destination.data(at: "/dst/a.bin"), payload)
    }

    // MARK: 7 — retried directory

    func testRetriedDirectoryDoesNotDuplicateMembers() async throws {
        let payload = Data(repeating: 2, count: 8_000)
        let source = InMemoryFileSource(
            files: ["/src/top/a.bin": payload, "/src/top/b.bin": payload],
            directories: ["/src", "/src/top"])
        source.listFailuresRemaining = 1
        let destination = InMemoryFileSource()
        let engine = TransferEngine(maxConcurrent: 1, maxAttempts: 3,
                                    retryDelay: .milliseconds(20))
        let tracker = TransferGroupTracker(engine: engine)

        let group = UUID()
        let root = downloadRequest(name: "top", sourcePath: "/src/top",
                                   destinationPath: "/dst/top", kind: .directory,
                                   groupID: group, source: source, destination: destination)
        let log = GroupEventLog(await tracker.open(group: group, root: root.id))
        await engine.enqueue(root)

        await assertEventually { log.finished != nil }
        XCTAssertEqual(log.finished, .completed)
        XCTAssertEqual(log.progressEvents.last?.itemsKnown, 3,
                       "root + 2 children — the retry must not re-add members")
        XCTAssertTrue(log.progressEvents.allSatisfy { $0.itemsKnown <= 3 })
        XCTAssertEqual(destination.data(at: "/dst/top/a.bin"), payload)
        XCTAssertEqual(destination.data(at: "/dst/top/b.bin"), payload)
    }

    // MARK: 8 — engine clearFinished mid-group

    func testClearFinishedMidGroupKeepsStreamAlive() async throws {
        let payload = Data(repeating: 4, count: 40_000)
        let source = InMemoryFileSource(
            files: ["/src/top/a.bin": payload, "/src/top/b.bin": payload],
            directories: ["/src", "/src/top"])
        let destination = InMemoryFileSource()
        destination.writeDelayNanoseconds = 30_000_000
        let engine = TransferEngine(maxConcurrent: 1)
        let tracker = TransferGroupTracker(engine: engine)

        let group = UUID()
        let root = downloadRequest(name: "top", sourcePath: "/src/top",
                                   destinationPath: "/dst/top", kind: .directory,
                                   groupID: group, source: source, destination: destination)
        let log = GroupEventLog(await tracker.open(group: group, root: root.id))
        await engine.enqueue(root)

        // Wait until the root directory has finished, then clear it from the
        // engine — the tracker keeps its own copy of every member seen.
        await assertEventually { log.progressEvents.contains { $0.itemsFinished >= 1 } }
        await engine.clearFinished()

        await assertEventually { log.finished != nil }
        XCTAssertEqual(log.finished, .completed)
        XCTAssertEqual(destination.data(at: "/dst/top/a.bin"), payload)
        XCTAssertEqual(destination.data(at: "/dst/top/b.bin"), payload)
    }

    // MARK: 9 — the vacuous-truth guard

    func testGroupWithNoEnqueuedRootNeverFinishes() async throws {
        let source = InMemoryFileSource(files: ["/src/other.bin": Data(repeating: 1, count: 100)])
        let destination = InMemoryFileSource()
        let engine = TransferEngine(maxConcurrent: 1)
        let tracker = TransferGroupTracker(engine: engine)

        let log = GroupEventLog(await tracker.open(group: UUID(), root: UUID()))
        // Unrelated (ungrouped) traffic proves the tracker is consuming and
        // still does not conclude the empty group.
        let other = downloadRequest(name: "other.bin", sourcePath: "/src/other.bin",
                                    destinationPath: "/dst/other.bin", groupID: nil,
                                    source: source, destination: destination)
        await engine.enqueue(other)
        _ = await firstSnapshot(engine: engine) { $0.id == other.id && $0.phase == .completed }

        await assertNever("a group whose root never enqueued must not vacuously finish") {
            log.finished != nil
        }
        XCTAssertTrue(log.events.isEmpty)
    }

    // MARK: 10 — group isolation

    func testGroupsAreIndependentAndUngroupedItemsIgnored() async throws {
        let payloadA = Data(repeating: 1, count: 10_000)
        let payloadB = Data(repeating: 2, count: 20_000)
        let source = InMemoryFileSource(files: ["/src/a.bin": payloadA,
                                                "/src/b.bin": payloadB,
                                                "/src/plain.bin": Data(repeating: 3, count: 5_000),
                                                "/src/orphan.bin": Data(repeating: 4, count: 5_000)])
        let destination = InMemoryFileSource()
        let engine = TransferEngine(maxConcurrent: 2)
        let tracker = TransferGroupTracker(engine: engine)

        let groupA = UUID()
        let groupB = UUID()
        let requestA = downloadRequest(name: "a.bin", sourcePath: "/src/a.bin",
                                       destinationPath: "/dst/a.bin", groupID: groupA,
                                       source: source, destination: destination)
        let requestB = downloadRequest(name: "b.bin", sourcePath: "/src/b.bin",
                                       destinationPath: "/dst/b.bin", groupID: groupB,
                                       source: source, destination: destination)
        // Ungrouped item + an item in a group nobody opened: both invisible.
        let plain = downloadRequest(name: "plain.bin", sourcePath: "/src/plain.bin",
                                    destinationPath: "/dst/plain.bin", groupID: nil,
                                    source: source, destination: destination)
        let orphan = downloadRequest(name: "orphan.bin", sourcePath: "/src/orphan.bin",
                                     destinationPath: "/dst/orphan.bin", groupID: UUID(),
                                     source: source, destination: destination)
        let logA = GroupEventLog(await tracker.open(group: groupA, root: requestA.id))
        let logB = GroupEventLog(await tracker.open(group: groupB, root: requestB.id))
        for request in [requestA, plain, orphan, requestB] {
            await engine.enqueue(request)
        }

        await assertEventually { logA.finished != nil && logB.finished != nil }
        XCTAssertEqual(logA.finished, .completed)
        XCTAssertEqual(logB.finished, .completed)
        XCTAssertEqual(logA.progressEvents.last?.itemsKnown, 1,
                       "group A must only ever see its own member")
        XCTAssertEqual(logB.progressEvents.last?.itemsKnown, 1)
        XCTAssertEqual(logA.progressEvents.last?.bytesTransferred, Int64(payloadA.count))
        XCTAssertEqual(logB.progressEvents.last?.bytesTransferred, Int64(payloadB.count))
    }

    // MARK: 11 — honest totals

    func testTotalBytesNilUntilEnumerationClosesAndBytesMonotonic() async throws {
        let a = Data(repeating: 1, count: 10_000)
        let b = Data(repeating: 2, count: 20_000)
        let source = InMemoryFileSource(
            files: ["/src/top/a.bin": a, "/src/top/sub/b.bin": b],
            directories: ["/src", "/src/top", "/src/top/sub"])
        let destination = InMemoryFileSource()
        destination.writeDelayNanoseconds = 10_000_000
        let engine = TransferEngine(maxConcurrent: 1)
        let tracker = TransferGroupTracker(engine: engine)

        let group = UUID()
        let root = downloadRequest(name: "top", sourcePath: "/src/top",
                                   destinationPath: "/dst/top", kind: .directory,
                                   groupID: group, source: source, destination: destination)
        let log = GroupEventLog(await tracker.open(group: group, root: root.id))
        await engine.enqueue(root)
        await assertEventually { log.finished != nil }
        XCTAssertEqual(log.finished, .completed)

        let progress = log.progressEvents
        XCTAssertNil(progress.first?.totalBytes,
                     "the total is unknown while enumeration is open")
        guard let firstKnown = progress.firstIndex(where: { $0.totalBytes != nil }) else {
            return XCTFail("the total must become known once enumeration closes")
        }
        XCTAssertGreaterThan(firstKnown, 0)
        for event in progress[firstKnown...] {
            XCTAssertEqual(event.totalBytes, Int64(a.count + b.count),
                           "once known, the total is the exact sum and never regresses to nil")
        }
        for (earlier, later) in zip(progress, progress.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.bytesTransferred, later.bytesTransferred,
                                     "aggregate bytes must be monotonic")
        }
        XCTAssertEqual(progress.last?.bytesTransferred, Int64(a.count + b.count))
    }

    // MARK: 12 — frozen conclusion

    func testConcludedGroupIsFrozenAgainstResume() async throws {
        let payload = Data(repeating: 7, count: 8_000)
        let source = InMemoryFileSource(files: ["/src/top/a.bin": payload],
                                        directories: ["/src", "/src/top"])
        source.listFailuresRemaining = 1
        let destination = InMemoryFileSource()
        let engine = TransferEngine(maxConcurrent: 1, maxAttempts: 1)
        let tracker = TransferGroupTracker(engine: engine)

        let group = UUID()
        let root = downloadRequest(name: "top", sourcePath: "/src/top",
                                   destinationPath: "/dst/top", kind: .directory,
                                   groupID: group, source: source, destination: destination)
        let log = GroupEventLog(await tracker.open(group: group, root: root.id))
        await engine.enqueue(root)

        await assertEventually { log.finished != nil }
        guard case .failed(let message)? = log.finished else {
            return XCTFail("expected .failed, got \(String(describing: log.finished))")
        }
        XCTAssertTrue(message.contains("injected list failure"), message)
        let eventCount = log.events.count

        // Resuming the failed directory re-enqueues members carrying the same
        // groupID — a concluded group must ignore them, not finish twice.
        await engine.resume(id: root.id)
        let childDone = await firstSnapshot(engine: engine) {
            $0.displayName == "a.bin" && $0.phase == .completed
        }
        XCTAssertNotNil(childDone, "the resume itself still works at the engine level")
        await assertNever("a concluded group must emit nothing more") {
            log.events.count > eventCount
        }
        XCTAssertEqual(log.finishedCount, 1)
    }
}
