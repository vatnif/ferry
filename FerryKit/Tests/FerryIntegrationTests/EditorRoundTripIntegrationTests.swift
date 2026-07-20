import XCTest
@testable import FerryCore

/// M19 editor round-trip. The app-layer tracker (`BrowserSession`) glues three
/// FerryCore pieces together — download a remote file to a temp copy
/// (`openRead`), watch that copy with `FileWatcher`, and on each save upload the
/// edited bytes back through the `TransferEngine`. The tracker itself lives in
/// the app target (not headless-testable), so these tests drive the exact same
/// composition against the real SFTP server, proving the mechanism end-to-end.
final class EditorRoundTripIntegrationTests: XCTestCase {
    private var source: SFTPSource!
    private var localDir: URL!
    private let local = LocalFileSource()

    override func setUp() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.sftpPort, serverName: "SFTP")
        source = try await TestServers.connectSFTP()
        localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await source?.disconnect()
        source = nil
        try? FileManager.default.removeItem(at: localDir)
    }

    /// Seeds a remote file, downloads it to a temp copy, and returns the copy.
    private func stageForEditing(remotePath: String, seed: Data) async throws -> URL {
        let handle = try await source.openWrite(at: remotePath, offset: 0)
        try await handle.write(seed)
        try await handle.close()

        let tempURL = localDir.appendingPathComponent("edit.txt")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tempURL)
        defer { try? fh.close() }
        for try await chunk in try await source.openRead(at: remotePath, offset: 0) {
            try fh.write(contentsOf: chunk)
        }
        XCTAssertEqual(try Data(contentsOf: tempURL), seed, "staged temp copy must match the server file")
        return tempURL
    }

    private func remoteContent(_ remotePath: String) async -> Data? {
        var data = Data()
        guard let stream = try? await source.openRead(at: remotePath, offset: 0) else { return nil }
        do {
            for try await chunk in stream { data += chunk }
        } catch {
            return nil
        }
        return data
    }

    /// Polls the server until its content matches `expected` (the watcher fires,
    /// then the queued upload lands), or times out.
    private func waitForRemote(_ remotePath: String, toEqual expected: Data,
                               timeout: TimeInterval = 25) async -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: Data?
        while Date() < deadline {
            latest = await remoteContent(remotePath) ?? latest
            if latest == expected { return latest }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return latest
    }

    /// Wires a watcher to auto-upload the temp copy back to `remotePath` on every
    /// save (`.restart`), exactly as `BrowserSession.uploadEdit` does.
    private func startRoundTrip(tempURL: URL, remotePath: String,
                                engine: TransferEngine) -> (FileWatcher, Task<Void, Never>) {
        let watcher = FileWatcher(path: tempURL.path, debounceMilliseconds: 100)
        let local = self.local
        let source = self.source!
        let task = Task {
            for await _ in watcher.changes {
                let request = TransferRequest(
                    direction: .upload, kind: .file, mode: .restart,
                    source: local, sourcePath: tempURL.path,
                    destination: source, destinationPath: remotePath,
                    displayName: tempURL.lastPathComponent)
                await engine.enqueue(request)
            }
        }
        return (watcher, task)
    }

    func testSaveUploadsEditedBytesBack() async throws {
        let source = self.source!
        let remotePath = "/upload/edit-\(UUID().uuidString.prefix(8)).txt"
        defer { Task { [source] in try? await source.delete(at: remotePath) } }

        let tempURL = try await stageForEditing(remotePath: remotePath,
                                                seed: Data("first version\n".utf8))
        let engine = TransferEngine(maxConcurrent: 1)
        let (watcher, task) = startRoundTrip(tempURL: tempURL, remotePath: remotePath, engine: engine)
        defer { watcher.cancel(); task.cancel() }
        try? await Task.sleep(nanoseconds: 250_000_000) // let the watcher arm

        // The user edits and saves (in-place write).
        let edited = Data("second version — edited then saved\n".utf8)
        try edited.write(to: tempURL)

        let landed = await waitForRemote(remotePath, toEqual: edited)
        XCTAssertEqual(landed, edited, "a save should upload the edited bytes back to the server")
    }

    func testAtomicSaveUploadsBack() async throws {
        let source = self.source!
        let remotePath = "/upload/edit-atomic-\(UUID().uuidString.prefix(8)).txt"
        defer { Task { [source] in try? await source.delete(at: remotePath) } }

        let tempURL = try await stageForEditing(remotePath: remotePath,
                                                seed: Data("original\n".utf8))
        let engine = TransferEngine(maxConcurrent: 1)
        let (watcher, task) = startRoundTrip(tempURL: tempURL, remotePath: remotePath, engine: engine)
        defer { watcher.cancel(); task.cancel() }
        try? await Task.sleep(nanoseconds: 250_000_000)

        // Most editors save atomically (write sibling + rename over) — the
        // watcher must re-arm and still trigger the upload.
        let edited = Data("rewritten atomically by the editor\n".utf8)
        try edited.write(to: tempURL, options: .atomic)

        let landed = await waitForRemote(remotePath, toEqual: edited)
        XCTAssertEqual(landed, edited, "an atomic save should still round-trip to the server")
    }
}
