import XCTest
@testable import FerryCore

/// In-memory FileSystemSource for engine tests: byte-exact, optionally slow
/// (to observe concurrency), tracks the peak number of simultaneous writes.
/// M9 additions: directories, rename/delete (for `.ferrypart` finalize),
/// modification dates (partial GC), and failure injection (retry policy).
final class InMemoryFileSource: FileSystemSource, @unchecked Sendable {
    let displayName = "memory"
    private let lock = NSLock()
    private var files: [String: Data]
    private var directories: Set<String> = []
    private var modificationDates: [String: Date] = [:]
    private var activeWrites = 0
    private(set) var peakConcurrentWrites = 0
    private(set) var writeStartOrder: [String] = []
    var writeDelayNanoseconds: UInt64 = 0
    /// Next N openRead calls throw `.io` (transient, retryable).
    var openReadFailuresRemaining = 0
    /// Next N list calls throw `.io` (transient, retryable) — lets a
    /// directory item fail and retry (TransferGroupTracker tests).
    var listFailuresRemaining = 0
    /// One-shot: the next write handle throws `.io` once its byte count
    /// would exceed this (data written so far stays — a real partial).
    var failNextWriteAfterBytes: Int?

    init(files: [String: Data] = [:], directories: Set<String> = []) {
        self.files = files
        self.directories = directories
    }

    func data(at path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return files[path]
    }

    func hasDirectory(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return directories.contains(path)
    }

    func setModificationDate(_ date: Date, at path: String) {
        lock.lock(); defer { lock.unlock() }
        modificationDates[path] = date
    }

    func homeDirectory() async throws -> String { "/" }
    func setPermissions(_ permissions: FilePermissions, at path: String) async throws {}

    /// NSLock scoping must stay in synchronous code (Swift 6 forbids
    /// lock/unlock spanning suspension points).
    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    func list(directory path: String, includeHidden: Bool) async throws -> [FileItem] {
        try synchronized {
        if listFailuresRemaining > 0 {
            listFailuresRemaining -= 1
            throw FileSystemSourceError.io("injected list failure")
        }
        guard directories.contains(path) else {
            throw FileSystemSourceError.notFound(path: path)
        }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var items: [FileItem] = []
        for (filePath, data) in files where filePath.hasPrefix(prefix)
            && !filePath.dropFirst(prefix.count).contains("/") {
            items.append(FileItem(name: String(filePath.dropFirst(prefix.count)),
                                  path: filePath, isDirectory: false, size: Int64(data.count)))
        }
        for directory in directories where directory.hasPrefix(prefix)
            && !directory.dropFirst(prefix.count).contains("/") {
            items.append(FileItem(name: String(directory.dropFirst(prefix.count)),
                                  path: directory, isDirectory: true))
        }
        return items
        }
    }

    func createDirectory(at path: String) async throws {
        try synchronized {
            if directories.contains(path) || files[path] != nil {
                throw FileSystemSourceError.alreadyExists(path: path)
            }
            directories.insert(path)
        }
    }

    func delete(at path: String) async throws {
        try synchronized {
            if files.removeValue(forKey: path) != nil { return }
            guard directories.contains(path) else {
                throw FileSystemSourceError.notFound(path: path)
            }
            let prefix = path + "/"
            directories = directories.filter { $0 != path && !$0.hasPrefix(prefix) }
            files = files.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    func rename(from sourcePath: String, to destinationPath: String) async throws {
        try synchronized {
            guard let data = files[sourcePath] else {
                throw FileSystemSourceError.notFound(path: sourcePath)
            }
            if files[destinationPath] != nil || directories.contains(destinationPath) {
                throw FileSystemSourceError.alreadyExists(path: destinationPath)
            }
            files.removeValue(forKey: sourcePath)
            files[destinationPath] = data
            modificationDates[destinationPath] = modificationDates.removeValue(forKey: sourcePath)
        }
    }

    func stat(path: String) async throws -> FileItem {
        try synchronized {
            if let data = files[path] {
                return FileItem(name: (path as NSString).lastPathComponent, path: path,
                                isDirectory: false, size: Int64(data.count),
                                modifiedAt: modificationDates[path])
            }
            if directories.contains(path) {
                return FileItem(name: (path as NSString).lastPathComponent, path: path,
                                isDirectory: true)
            }
            throw FileSystemSourceError.notFound(path: path)
        }
    }

    func openRead(at path: String, offset: Int64) async throws -> AsyncThrowingStream<Data, Error> {
        try synchronized {
            if openReadFailuresRemaining > 0 {
                openReadFailuresRemaining -= 1
                throw FileSystemSourceError.io("injected read failure")
            }
        }
        guard let data = data(at: path) else { throw FileSystemSourceError.notFound(path: path) }
        let payload = data.dropFirst(Int(offset))
        return AsyncThrowingStream { continuation in
            // Multiple small chunks so progress updates and cancellation
            // points actually occur.
            let chunkSize = max(1, payload.count / 4)
            var index = payload.startIndex
            while index < payload.endIndex {
                let end = min(index + chunkSize, payload.endIndex)
                continuation.yield(Data(payload[index..<end]))
                index = end
            }
            continuation.finish()
        }
    }

    func openWrite(at path: String, offset: Int64) async throws -> any FileWriteHandle {
        let failAfter: Int? = try synchronized {
            if offset > 0, files[path] == nil {
                throw FileSystemSourceError.notFound(path: path)
            }
            let value = failNextWriteAfterBytes
            failNextWriteAfterBytes = nil
            return value
        }
        beginWrite(path: path, offset: offset)
        return Handle(source: self, path: path, delay: writeDelayNanoseconds,
                      bytesWritten: Int(offset), failAfterBytes: failAfter)
    }

    private func beginWrite(path: String, offset: Int64) {
        lock.lock(); defer { lock.unlock() }
        activeWrites += 1
        peakConcurrentWrites = max(peakConcurrentWrites, activeWrites)
        writeStartOrder.append(path)
        files[path] = (files[path] ?? Data()).prefix(Int(offset))
    }

    fileprivate func append(_ data: Data, to path: String) {
        lock.lock(); defer { lock.unlock() }
        files[path, default: Data()].append(data)
    }

    fileprivate func writeFinished() {
        lock.lock(); defer { lock.unlock() }
        activeWrites -= 1
    }

    private final class Handle: FileWriteHandle, @unchecked Sendable {
        let source: InMemoryFileSource
        let path: String
        let delay: UInt64
        let failAfterBytes: Int?
        private let lock = NSLock()
        private var bytesWritten: Int
        private var closed = false

        init(source: InMemoryFileSource, path: String, delay: UInt64,
             bytesWritten: Int, failAfterBytes: Int?) {
            self.source = source
            self.path = path
            self.delay = delay
            self.bytesWritten = bytesWritten
            self.failAfterBytes = failAfterBytes
        }

        /// A closed handle refuses writes, like the real backends — this
        /// is what stops a cancelled task's zombie write (ADR-013).
        private func admitWrite(byteCount: Int) throws {
            lock.lock(); defer { lock.unlock() }
            guard !closed else {
                throw FileSystemSourceError.io("write after close")
            }
            if let failAfterBytes, bytesWritten + byteCount > failAfterBytes {
                throw FileSystemSourceError.io("injected write failure")
            }
            bytesWritten += byteCount
        }

        private func claimClose() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if closed { return false }
            closed = true
            return true
        }

        func write(_ data: Data) async throws {
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            try admitWrite(byteCount: data.count)
            source.append(data, to: path)
        }

        func close() async throws {
            guard claimClose() else { return }
            source.writeFinished()
        }
    }
}

final class TransferEngineTests: XCTestCase {
    private func request(_ name: String,
                         from source: InMemoryFileSource,
                         to destination: InMemoryFileSource) -> TransferRequest {
        TransferRequest(direction: .download,
                        source: source, sourcePath: "/src/\(name)",
                        destination: destination, destinationPath: "/dst/\(name)",
                        displayName: name)
    }

    /// Collects snapshots until every enqueued id reaches a finished phase.
    private func runUntilFinished(engine: TransferEngine, ids: Set<UUID>,
                                  timeout: TimeInterval = 10) async -> [UUID: TransferSnapshot] {
        var final: [UUID: TransferSnapshot] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        for await snapshot in await engine.events() {
            if ids.contains(snapshot.id) { final[snapshot.id] = snapshot }
            if ids.allSatisfy({ final[$0]?.phase.isFinished == true }) { break }
            if Date() > deadline { break }
        }
        return final
    }

    func testCopiesByteExactWithProgress() async throws {
        let payload = Data((0..<100_000).map { UInt8($0 % 256) })
        let source = InMemoryFileSource(files: ["/src/a.bin": payload])
        let destination = InMemoryFileSource()
        let engine = TransferEngine(maxConcurrent: 1)

        let request = request("a.bin", from: source, to: destination)
        await engine.enqueue(request)

        var sawProgress = false
        var last: TransferSnapshot?
        for await snapshot in await engine.events() {
            if case .running = snapshot.phase, snapshot.bytesTransferred > 0 { sawProgress = true }
            last = snapshot
            if snapshot.phase.isFinished { break }
        }

        XCTAssertEqual(last?.phase, .completed)
        XCTAssertEqual(last?.bytesTransferred, Int64(payload.count))
        XCTAssertEqual(last?.totalBytes, Int64(payload.count))
        XCTAssertTrue(sawProgress, "must emit intermediate progress")
        XCTAssertEqual(destination.data(at: "/dst/a.bin"), payload)
    }

    func testConcurrencyCapAndFIFOStartOrder() async throws {
        let names = (0..<6).map { "f\($0).bin" }
        let source = InMemoryFileSource(files: Dictionary(uniqueKeysWithValues:
            names.map { ("/src/\($0)", Data(repeating: 7, count: 4000)) }))
        let destination = InMemoryFileSource()
        destination.writeDelayNanoseconds = 30_000_000 // 30 ms per chunk
        let engine = TransferEngine(maxConcurrent: 2)

        var ids = Set<UUID>()
        for name in names {
            let request = request(name, from: source, to: destination)
            ids.insert(request.id)
            await engine.enqueue(request)
        }
        let final = await runUntilFinished(engine: engine, ids: ids)

        XCTAssertTrue(final.values.allSatisfy { $0.phase == .completed })
        XCTAssertLessThanOrEqual(destination.peakConcurrentWrites, 2,
                                 "cap of 2 must never be exceeded")
        // Dequeue order is FIFO, but the ≤2 concurrently-started tasks may
        // race to openWrite — so an item can start at most cap−1 positions
        // away from its queue position, never more. (Downloads write to
        // `<name>.ferrypart` since M9 — strip the suffix before comparing.)
        let startOrder = destination.writeStartOrder.map {
            ($0 as NSString).lastPathComponent
                .replacingOccurrences(of: TransferEngine.partialSuffix, with: "")
        }
        XCTAssertEqual(Set(startOrder), Set(names))
        for (position, name) in startOrder.enumerated() {
            let queuePosition = names.firstIndex(of: name)!
            XCTAssertLessThanOrEqual(abs(position - queuePosition), 1,
                                     "\(name) started \(abs(position - queuePosition)) positions out of FIFO order")
        }
        for name in names {
            XCTAssertEqual(destination.data(at: "/dst/\(name)")?.count, 4000)
        }
    }

    func testCancelQueuedItem() async throws {
        let source = InMemoryFileSource(files: ["/src/slow.bin": Data(repeating: 1, count: 4000),
                                                "/src/waiting.bin": Data(repeating: 2, count: 4000)])
        let destination = InMemoryFileSource()
        destination.writeDelayNanoseconds = 50_000_000
        let engine = TransferEngine(maxConcurrent: 1)

        let running = request("slow.bin", from: source, to: destination)
        let queued = request("waiting.bin", from: source, to: destination)
        await engine.enqueue(running)
        await engine.enqueue(queued)
        await engine.cancel(id: queued.id)

        let final = await runUntilFinished(engine: engine, ids: [running.id, queued.id])
        XCTAssertEqual(final[running.id]?.phase, .completed)
        XCTAssertEqual(final[queued.id]?.phase, .cancelled)
        XCTAssertNil(destination.data(at: "/dst/waiting.bin"))
    }

    func testCancelRunningItemStopsMidway() async throws {
        let source = InMemoryFileSource(files: ["/src/big.bin": Data(repeating: 9, count: 40_000)])
        let destination = InMemoryFileSource()
        destination.writeDelayNanoseconds = 60_000_000 // 4 chunks ⇒ ~240 ms total
        let engine = TransferEngine(maxConcurrent: 1)

        let request = request("big.bin", from: source, to: destination)
        await engine.enqueue(request)
        try await Task.sleep(nanoseconds: 90_000_000) // let ~1-2 chunks through
        await engine.cancel(id: request.id)

        let final = await runUntilFinished(engine: engine, ids: [request.id])
        XCTAssertEqual(final[request.id]?.phase, .cancelled)
        let written = destination.data(at: "/dst/big.bin")?.count ?? 0
        XCTAssertLessThan(written, 40_000, "cancelled transfer must not complete")
    }

    func testFailureFreesTheSlot() async throws {
        let source = InMemoryFileSource(files: ["/src/ok.bin": Data(repeating: 3, count: 100)])
        let destination = InMemoryFileSource()
        let engine = TransferEngine(maxConcurrent: 1)

        let missing = request("ghost.bin", from: source, to: destination) // no such source file
        let good = request("ok.bin", from: source, to: destination)
        await engine.enqueue(missing)
        await engine.enqueue(good)

        let final = await runUntilFinished(engine: engine, ids: [missing.id, good.id])
        guard case .failed(let message)? = final[missing.id]?.phase else {
            return XCTFail("expected failure, got \(String(describing: final[missing.id]?.phase))")
        }
        XCTAssertTrue(message.contains("notFound"), message)
        XCTAssertEqual(final[good.id]?.phase, .completed,
                       "a failure must not wedge the queue")
    }

    func testLateSubscriberGetsReplay() async throws {
        let source = InMemoryFileSource(files: ["/src/a.bin": Data(repeating: 5, count: 100)])
        let destination = InMemoryFileSource()
        let engine = TransferEngine(maxConcurrent: 1)
        let request = request("a.bin", from: source, to: destination)
        await engine.enqueue(request)
        _ = await runUntilFinished(engine: engine, ids: [request.id])

        // Fresh subscriber still sees the completed item (replay).
        for await snapshot in await engine.events() {
            XCTAssertEqual(snapshot.id, request.id)
            XCTAssertEqual(snapshot.phase, .completed)
            break
        }

        await engine.clearFinished()
        let replayedAfterClear = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in await engine.events() { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 100_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertFalse(replayedAfterClear, "cleared items must not be replayed")
    }
}
