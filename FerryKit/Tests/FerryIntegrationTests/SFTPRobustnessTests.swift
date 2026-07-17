import CryptoKit
import XCTest
@testable import FerryCore

/// M9 integration tests against the Docker SFTP server: kill-mid-transfer
/// with byte-exact `.ferrypart` resume, retry self-healing after reconnect,
/// pause/resume of uploads, folder transfers, mkdir with intermediates, and
/// supervisor-driven reconnection.
final class SFTPRobustnessTests: XCTestCase {
    private var source: SFTPSource!
    private var localDir: URL!
    private let local = LocalFileSource()

    override func setUp() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.sftpPort, serverName: "SFTP")
        source = try await TestServers.connectSFTP()
        localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-m9-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await source?.disconnect()
        source = nil
        try? FileManager.default.removeItem(at: localDir)
    }

    // MARK: Helpers

    /// Runs a shell command inside the SFTP test container; nil on failure.
    @discardableResult
    private static func shellInContainer(_ command: String,
                                         ignoreStatus: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "exec", "ferry-test-sftp", "sh", "-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":/usr/local/bin"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard ignoreStatus || process.terminationStatus == 0 else { return nil }
        return String(decoding: output, as: UTF8.self)
    }

    /// Kills the per-session sshd processes inside the test container — a
    /// real network-level drop as the client sees it. (Closing the local
    /// SSHClient mid-read is NOT an option: NIOSSH fatalErrors adjusting the
    /// window of a channel with in-flight reads.) OpenSSH ≥ 9.8 runs
    /// sessions as `sshd-session`; older images show `sshd: user` — kill
    /// both patterns, never PID 1 (`/usr/sbin/sshd`, which matches neither).
    private static func killServerSessions() {
        shellInContainer("pkill -f sshd-session; pkill -f 'sshd: ferry'", ignoreStatus: true)
    }

    /// Seeds a big random remote file server-side (instant — no SFTP upload)
    /// and returns its md5. Kill-mid-transfer needs a file large enough that
    /// the ~300 ms `docker exec pkill` lands before the download finishes.
    private static func seedLargeRemoteFile(megabytes: Int, sftpPath: String) -> String? {
        let containerPath = "/home/ferry" + sftpPath
        guard shellInContainer("dd if=/dev/urandom of=\(containerPath) bs=1048576 " +
                               "count=\(megabytes) 2>/dev/null && chmod 644 \(containerPath)") != nil
        else { return nil }
        return shellInContainer("md5sum \(containerPath)")?
            .split(separator: " ").first.map(String.init)
    }

    private static func md5(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makePayload(bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(($0 &* 131) % 251) })
    }

    private func readRemote(_ path: String) async throws -> Data {
        var data = Data()
        for try await chunk in try await source.openRead(at: path, offset: 0) { data += chunk }
        return data
    }

    /// Hard timeout by racing, not by checking a deadline on event arrival —
    /// the failure mode M9 exists for is a stream that goes silent forever,
    /// and a deadline check inside `for await` never runs then (this exact
    /// bug hung the first M9 test run).
    private func race<T: Sendable>(timeout: TimeInterval,
                                   _ body: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func waitForFinish(engine: TransferEngine, id: UUID,
                               timeout: TimeInterval = 60) async -> TransferSnapshot? {
        await race(timeout: timeout) {
            for await snapshot in await engine.events() {
                if snapshot.id == id, snapshot.phase.isFinished { return snapshot }
            }
            return nil
        }
    }

    /// Terminal snapshot plus the resume offset observed on the way (RESUMED).
    private func waitForFinishTrackingResume(engine: TransferEngine, id: UUID,
                                             timeout: TimeInterval = 60)
        async -> (final: TransferSnapshot?, resumedFrom: Int64?) {
        let result: (TransferSnapshot, Int64?)? = await race(timeout: timeout) {
            var resumedFrom: Int64?
            for await snapshot in await engine.events() where snapshot.id == id {
                if let offset = snapshot.resumedFromOffset { resumedFrom = offset }
                if snapshot.phase.isFinished { return (snapshot, resumedFrom) }
            }
            return nil
        }
        return (result?.0, result?.1)
    }

    /// Runs `sabotage` once the transfer shows real progress (but is not
    /// finished yet); fails the test if it finishes without any progress or
    /// never shows any.
    private func onFirstProgress(engine: TransferEngine, id: UUID,
                                 timeout: TimeInterval = 60,
                                 sabotage: @escaping @Sendable () async -> Void) async {
        enum Outcome: Sendable { case sabotaged, finishedEarly(String) }
        let outcome: Outcome? = await race(timeout: timeout) {
            for await snapshot in await engine.events() where snapshot.id == id {
                if snapshot.phase == .running, snapshot.bytesTransferred > 0,
                   snapshot.bytesTransferred < (snapshot.totalBytes ?? .max) {
                    await sabotage()
                    return .sabotaged
                }
                if snapshot.phase.isFinished {
                    return .finishedEarly(String(describing: snapshot.phase))
                }
            }
            return nil
        }
        switch outcome {
        case .sabotaged: break
        case .finishedEarly(let phase): XCTFail("transfer ended before any progress: \(phase)")
        case nil: XCTFail("no transfer progress within \(Int(timeout))s")
        }
    }

    // MARK: Kill mid-transfer + resume (the M9 headline scenario)

    func testKilledDownloadLeavesPartialAndResumesByteExact() async throws {
        let remotePath = "/upload/killme-\(UUID().uuidString.prefix(8)).bin"
        guard let expectedMD5 = Self.seedLargeRemoteFile(megabytes: 32, sftpPath: remotePath) else {
            return XCTFail("could not seed the remote file via docker exec")
        }
        let totalBytes = 32 * 1_048_576
        let source = self.source!
        defer { Task { [source] in try? await source.delete(at: remotePath) } }

        let localFile = localDir.appendingPathComponent("killme.bin")
        // maxAttempts 1: no auto-retry, so the kill surfaces as ERROR and we
        // exercise the manual resume path.
        let engine = TransferEngine(maxConcurrent: 1, maxAttempts: 1,
                                    retryDelay: .milliseconds(50))
        let request = TransferRequest(direction: .download,
                                      source: source, sourcePath: remotePath,
                                      destination: local, destinationPath: localFile.path,
                                      displayName: "killme.bin")
        await engine.enqueue(request)

        // Kill the connection mid-transfer (server side, like a real drop).
        await onFirstProgress(engine: engine, id: request.id) {
            Self.killServerSessions()
        }
        let failed = await waitForFinish(engine: engine, id: request.id)
        guard case .failed = failed?.phase else {
            return XCTFail("expected failed after connection kill, got \(String(describing: failed?.phase))")
        }

        // The partial must exist, be incomplete, and the final must not.
        let partialPath = localFile.path + TransferEngine.partialSuffix
        let partialSize = (try? FileManager.default
            .attributesOfItem(atPath: partialPath)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(partialSize, 0, ".ferrypart must survive the kill")
        XCTAssertLessThan(partialSize, totalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localFile.path))

        // Reconnect and resume: byte-exact completion from the partial.
        try await source.reestablish()
        await engine.resume(id: request.id)

        let (final, resumedOffset) = await waitForFinishTrackingResume(engine: engine,
                                                                       id: request.id, timeout: 120)
        XCTAssertEqual(final?.phase, .completed)
        XCTAssertEqual(resumedOffset, Int64(partialSize),
                       "resume must continue exactly at the partial's size")
        XCTAssertEqual(try Self.md5(of: localFile), expectedMD5,
                       "killed + resumed download must be byte-exact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialPath),
                       "partial must be renamed away on completion")
    }

    func testRetryPolicySelfHealsAfterReconnect() async throws {
        let remotePath = "/upload/selfheal-\(UUID().uuidString.prefix(8)).bin"
        guard let expectedMD5 = Self.seedLargeRemoteFile(megabytes: 32, sftpPath: remotePath) else {
            return XCTFail("could not seed the remote file via docker exec")
        }
        let source = self.source!
        defer { Task { [source] in try? await source.delete(at: remotePath) } }

        let localFile = localDir.appendingPathComponent("selfheal.bin")
        let engine = TransferEngine(maxConcurrent: 1, maxAttempts: 3,
                                    retryDelay: .milliseconds(800))
        let request = TransferRequest(direction: .download,
                                      source: source, sourcePath: remotePath,
                                      destination: local, destinationPath: localFile.path,
                                      displayName: "selfheal.bin")
        await engine.enqueue(request)

        // Kill mid-transfer, then bring the connection back while the engine
        // is in its retry backoff — no user involvement.
        await onFirstProgress(engine: engine, id: request.id) {
            Self.killServerSessions()
        }
        Task { [source] in
            try? await Task.sleep(for: .milliseconds(200))
            try? await source.reestablish()
        }

        let final = await waitForFinish(engine: engine, id: request.id, timeout: 120)
        XCTAssertEqual(final?.phase, .completed,
                       "the retry policy must recover once the link is back")
        XCTAssertGreaterThan(final?.attempt ?? 0, 1, "recovery must be a retry, not first try")
        XCTAssertEqual(try Self.md5(of: localFile), expectedMD5)
    }

    // MARK: Pause / resume (upload direction)

    func testPausedUploadResumesFromRemoteSize() async throws {
        let payload = makePayload(bytes: 2_000_000)
        let localFile = localDir.appendingPathComponent("pausable.bin")
        try payload.write(to: localFile)
        let remotePath = "/upload/pausable-\(UUID().uuidString.prefix(8)).bin"
        let source = self.source!
        defer { Task { [source] in try? await source.delete(at: remotePath) } }

        let engine = TransferEngine(maxConcurrent: 1)
        let request = TransferRequest(direction: .upload,
                                      source: local, sourcePath: localFile.path,
                                      destination: source, destinationPath: remotePath,
                                      displayName: "pausable.bin")
        await engine.enqueue(request)

        await onFirstProgress(engine: engine, id: request.id) {
            await engine.pause(id: request.id)
        }
        // Let the interrupted task's last write settle, then check the partial.
        try await Task.sleep(for: .milliseconds(500))
        let remoteSize = try await source.stat(path: remotePath).size ?? 0
        XCTAssertGreaterThan(remoteSize, 0, "pause must leave the partial upload in place")
        XCTAssertLessThan(remoteSize, Int64(payload.count))

        await engine.resume(id: request.id)
        let (final, resumedOffset) = await waitForFinishTrackingResume(engine: engine,
                                                                       id: request.id)
        XCTAssertEqual(final?.phase, .completed)
        XCTAssertGreaterThan(resumedOffset ?? 0, 0, "resume must continue from the remote size")
        let roundTrip = try await readRemote(remotePath)
        XCTAssertEqual(roundTrip, payload, "paused + resumed upload must be byte-exact")
    }

    // MARK: Folder transfers

    func testFolderUploadAndDownloadRoundTrip() async throws {
        // Local tree: folder/a.txt, folder/sub/b.bin
        let folder = localDir.appendingPathComponent("folder", isDirectory: true)
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let fileA = Data("hello folder transfers".utf8)
        let fileB = makePayload(bytes: 100_000)
        try fileA.write(to: folder.appendingPathComponent("a.txt"))
        try fileB.write(to: sub.appendingPathComponent("b.bin"))

        let remoteFolder = "/upload/folder-\(UUID().uuidString.prefix(8))"
        let source = self.source!
        defer { Task { [source] in try? await source.delete(at: remoteFolder) } }

        let engine = TransferEngine(maxConcurrent: 2)
        let upload = TransferRequest(direction: .upload, kind: .directory,
                                     source: local, sourcePath: folder.path,
                                     destination: source, destinationPath: remoteFolder,
                                     displayName: "folder")
        await engine.enqueue(upload)

        try await waitForNames(["folder", "a.txt", "sub", "b.bin"], engine: engine)
        let remoteA = try await readRemote(remoteFolder + "/a.txt")
        let remoteB = try await readRemote(remoteFolder + "/sub/b.bin")
        XCTAssertEqual(remoteA, fileA)
        XCTAssertEqual(remoteB, fileB)
        let subStat = try await source.stat(path: remoteFolder + "/sub")
        XCTAssertTrue(subStat.isDirectory)

        // And back down into a fresh local directory.
        let downloadTarget = localDir.appendingPathComponent("roundtrip", isDirectory: true)
        let download = TransferRequest(direction: .download, kind: .directory,
                                       source: source, sourcePath: remoteFolder,
                                       destination: local, destinationPath: downloadTarget.path,
                                       displayName: "roundtrip")
        await engine.enqueue(download)
        try await waitForNames(["roundtrip", "a.txt", "sub", "b.bin"], engine: engine,
                               skipFinished: 4)

        XCTAssertEqual(try Data(contentsOf: downloadTarget.appendingPathComponent("a.txt")), fileA)
        XCTAssertEqual(try Data(contentsOf: downloadTarget
            .appendingPathComponent("sub/b.bin")), fileB)
    }

    /// Waits until every display name reached `.completed`; `skipFinished`
    /// replayed completions (from an earlier phase of the test) are ignored
    /// by requiring that many extra completion events.
    private func waitForNames(_ names: Set<String>, engine: TransferEngine,
                              timeout: TimeInterval = 90, skipFinished: Int = 0) async throws {
        struct Outcome: Sendable {
            var completed: [String: Int] = [:]
            var failures: [String] = []
        }
        let outcome: Outcome? = await race(timeout: timeout) {
            var state = Outcome()
            for await snapshot in await engine.events() {
                if snapshot.phase == .completed {
                    state.completed[snapshot.displayName, default: 0] += 1
                }
                if case .failed(let message) = snapshot.phase {
                    state.failures.append("\(snapshot.displayName): \(message)")
                    return state
                }
                let distinctDone = names.filter { (state.completed[$0] ?? 0) > 0 }.count
                if state.completed.values.reduce(0, +) >= names.count + skipFinished,
                   distinctDone == names.count { return state }
            }
            return state
        }
        guard let outcome else { return XCTFail("folder transfer timed out after \(Int(timeout))s") }
        XCTAssertTrue(outcome.failures.isEmpty, "transfers failed: \(outcome.failures)")
        for name in names {
            XCTAssertGreaterThan(outcome.completed[name] ?? 0, 0, "\(name) never completed")
        }
    }

    // MARK: SFTP mkdir (pulled forward for folder transfers)

    func testCreateDirectoryWithIntermediatesAndAlreadyExists() async throws {
        let base = "/upload/nest-\(UUID().uuidString.prefix(8))"
        let nested = base + "/one/two"
        let source = self.source!
        defer { Task { [source] in try? await source.delete(at: base) } }

        try await source.createDirectory(at: nested)
        let stat = try await source.stat(path: nested)
        XCTAssertTrue(stat.isDirectory, "intermediates must be created")

        await XCTAssertThrowsErrorAsync(try await self.source.createDirectory(at: nested)) {
            guard case .alreadyExists = $0 as? FileSystemSourceError else {
                return XCTFail("expected alreadyExists, got \($0)")
            }
        }
    }

    // MARK: Supervisor + real reconnect

    func testSupervisorReconnectsDroppedConnection() async throws {
        let supervised = try await TestServers.connectSFTP()
        let supervisor = ConnectionSupervisor(connection: supervised,
                                              pingInterval: .milliseconds(150),
                                              maxAttempts: 3,
                                              backoff: .milliseconds(100))
        let stream = await supervisor.events()
        await supervisor.start()

        // Simulate the drop (kills every live ferry session, including the
        // setUp connection — unused for the rest of this test).
        Self.killServerSessions()

        let recovered: Bool? = await race(timeout: 20) {
            var sawReconnecting = false
            for await state in stream {
                if case .reconnecting = state { sawReconnecting = true }
                if state == .connected, sawReconnecting { return true }
            }
            return false
        }
        await supervisor.stop()

        XCTAssertEqual(recovered, true,
                       "keep-alive must detect the dead link and reestablish it")
        // The rebuilt transport actually works.
        let listing = try await supervised.list(directory: "/", includeHidden: false)
        XCTAssertFalse(listing.isEmpty)
        await supervised.disconnect()
    }
}
