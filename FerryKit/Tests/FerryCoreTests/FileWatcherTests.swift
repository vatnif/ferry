import XCTest
@testable import FerryCore

/// Tests the net-new `DispatchSource` file watcher (M19) against real temp
/// files — the milestone's genuinely risky piece. Covers a plain in-place save,
/// coalescing of a write burst into one emission, and the atomic
/// write-then-rename save that most editors use (which replaces the watched
/// inode and must re-arm).
final class FileWatcherTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FerryFileWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    /// A main-actor-free emission counter fed by the watcher's stream.
    private actor Counter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    private func startCounting(_ watcher: FileWatcher) -> (Counter, Task<Void, Never>) {
        let counter = Counter()
        let task = Task { for await _ in watcher.changes { await counter.bump() } }
        return (counter, task)
    }

    private func wait(for counter: Counter, atLeast target: Int, timeout: TimeInterval = 3) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let c = await counter.count
            if c >= target { return c }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await counter.count
    }

    private func settle() async {
        // Let the watcher open its descriptor on its serial queue before we
        // start mutating the file.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: Tests

    func testPlainWriteFiresOnce() async throws {
        let file = directory.appendingPathComponent("notes.txt")
        try "one".data(using: .utf8)!.write(to: file)

        let watcher = FileWatcher(path: file.path, debounceMilliseconds: 100)
        let (counter, task) = startCounting(watcher)
        defer { watcher.cancel(); task.cancel() }
        await settle()

        try "one — edited".data(using: .utf8)!.write(to: file)

        let count = await wait(for: counter, atLeast: 1)
        XCTAssertGreaterThanOrEqual(count, 1, "an in-place save should emit a change")
    }

    func testBurstCoalescesToOne() async throws {
        let file = directory.appendingPathComponent("burst.txt")
        try "start".data(using: .utf8)!.write(to: file)

        let watcher = FileWatcher(path: file.path, debounceMilliseconds: 300)
        let (counter, task) = startCounting(watcher)
        defer { watcher.cancel(); task.cancel() }
        await settle()

        // Several writes back-to-back, all inside one debounce window.
        for i in 0..<5 {
            try "edit \(i)".data(using: .utf8)!.write(to: file)
        }

        // Wait past the debounce window, then confirm the burst collapsed.
        _ = await wait(for: counter, atLeast: 1)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let count = await counter.count
        XCTAssertEqual(count, 1, "a burst of writes should coalesce into one emission")
    }

    func testAtomicRenameOverStillFires() async throws {
        let file = directory.appendingPathComponent("atomic.txt")
        try "original".data(using: .utf8)!.write(to: file)

        let watcher = FileWatcher(path: file.path, debounceMilliseconds: 100)
        let (counter, task) = startCounting(watcher)
        defer { watcher.cancel(); task.cancel() }
        await settle()

        // `.atomic` writes to a sibling temp file and renames it over the
        // target — the write-then-rename save that replaces the inode.
        try "replaced atomically".data(using: .utf8)!.write(to: file, options: .atomic)

        let count = await wait(for: counter, atLeast: 1)
        XCTAssertGreaterThanOrEqual(count, 1, "an atomic (rename-over) save should still emit a change")
    }

    func testAtomicSaveReArmsForSubsequentSaves() async throws {
        let file = directory.appendingPathComponent("resave.txt")
        try "v0".data(using: .utf8)!.write(to: file)

        let watcher = FileWatcher(path: file.path, debounceMilliseconds: 100)
        let (counter, task) = startCounting(watcher)
        defer { watcher.cancel(); task.cancel() }
        await settle()

        // First atomic save re-arms onto the new inode…
        try "v1".data(using: .utf8)!.write(to: file, options: .atomic)
        _ = await wait(for: counter, atLeast: 1)
        // …give the re-arm time to reopen the fresh file.
        try? await Task.sleep(nanoseconds: 300_000_000)

        // …a second atomic save must be seen too.
        try "v2".data(using: .utf8)!.write(to: file, options: .atomic)
        let count = await wait(for: counter, atLeast: 2)
        XCTAssertGreaterThanOrEqual(count, 2, "the watcher must re-arm after an atomic save and see the next one")
    }

    func testCancelFinishesStream() async throws {
        let file = directory.appendingPathComponent("cancel.txt")
        try "x".data(using: .utf8)!.write(to: file)

        let watcher = FileWatcher(path: file.path, debounceMilliseconds: 100)
        let finished = expectation(description: "stream finished")
        let task = Task {
            for await _ in watcher.changes {}
            finished.fulfill()
        }
        await settle()

        watcher.cancel()
        await fulfillment(of: [finished], timeout: 2)
        task.cancel()
    }
}
