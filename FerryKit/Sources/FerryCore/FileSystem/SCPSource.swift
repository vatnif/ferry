@preconcurrency import Citadel
import Foundation
import NIOCore

/// A `FileSystemSource` over **SCP**, run across an SSH exec channel and reusing
/// the M11 SSH stack (host-key TOFU + password/key auth via `SSHClientFactory`).
/// ADR-020.
///
/// SCP is a much weaker protocol than SFTP: the classic scp wire protocol
/// (`scp -f`/`scp -t`) only transfers file bytes and carries **no** listing,
/// stat, mkdir, delete, rename, or chmod. So `SCPSource` splits the
/// `FileSystemSource` surface in two:
///
/// - **Metadata** (home/list/stat/mkdir/delete/rename/chmod) runs ordinary
///   POSIX commands over the exec channel (`pwd`, `ls -la`, `mkdir -p`,
///   `rm -rf`, `mv`, `chmod`) — parsed with the shared Unix `ls -l` parser.
/// - **Bytes** stream over the real scp protocol: `openRead` drives `scp -f`
///   (source→sink) and `openWrite` drives `scp -t` (sink←source).
///
/// Because it needs Citadel's bidirectional exec channel (`withExec`), which is
/// macOS 15+, the whole type is `@available(macOS 15.0, *)` (the app gates the
/// SCP connect path accordingly). Capability compromises vs SFTP are documented
/// in DOMAIN.md → SCP.
@available(macOS 15.0, *)
public actor SCPSource: FileSystemSource {
    public nonisolated let displayName: String
    private var ssh: SSHClient
    /// Shared with SFTPSource; enables an identical auto-reconnect (M9).
    private let parameters: SSHConnectionParameters

    /// Transfer chunk size, matching SFTPSource's read chunk.
    static let chunkLength = 128 * 1024
    /// Remote staging suffix for uploads (see `openWrite`).
    static let uploadStagingSuffix = ".ferry-scp-part"

    private init(displayName: String, ssh: SSHClient, parameters: SSHConnectionParameters) {
        self.displayName = displayName
        self.ssh = ssh
        self.parameters = parameters
    }

    /// Establishes an SSH transport (TOFU host-key verification + auth, shared
    /// with SFTP) and confirms the server actually allows command execution.
    ///
    /// Throws the same `RemoteSourceError`s as `SFTPSource.connect`, plus
    /// `.connectionFailed` with a clear message when the login succeeds but the
    /// server forbids exec (e.g. an SFTP-only server with
    /// `ForceCommand internal-sftp`), where SCP cannot work.
    public static func connect(host: String,
                               port: Int = 22,
                               username: String,
                               credential: SSHAuthCredential,
                               hostKeyStore: HostKeyStore,
                               systemKnownHosts: KnownHostsFile? = nil,
                               sessionTrusted: HostKeyInfo? = nil,
                               displayName: String? = nil) async throws -> SCPSource {
        let parameters = SSHConnectionParameters(host: host, port: port, username: username,
                                                 credential: credential, hostKeyStore: hostKeyStore,
                                                 systemKnownHosts: systemKnownHosts,
                                                 sessionTrusted: sessionTrusted)
        let ssh = try await SSHClientFactory.connect(parameters)
        let source = SCPSource(displayName: displayName ?? host, ssh: ssh, parameters: parameters)
        try await source.probeExec()
        return source
    }

    /// A login can succeed on an SFTP-only server that silently ignores (or
    /// refuses) exec requests, which would turn every SCP operation into a
    /// confusing failure. Detect it once, up front, with a marker echo.
    private func probeExec() async throws {
        let marker = "ferry_scp_ready"
        let ok = (try? await run("echo \(marker)"))
            .map { String(decoding: $0.stdout, as: UTF8.self).contains(marker) } ?? false
        guard ok else {
            throw RemoteSourceError.connectionFailed(
                "The server accepted the SSH login but does not allow running commands, "
                + "so SCP is unavailable. This is common on SFTP-only servers — "
                + "use SFTP for this connection instead.")
        }
    }

    // MARK: - SupervisedConnection (keep-alive / auto-reconnect, M9)

    /// Proves the exec channel is alive (a no-op remote command).
    public func ping() async throws {
        _ = try await run("true")
    }

    public func reestablish() async throws {
        try? await ssh.close()
        ssh = try await SSHClientFactory.connect(parameters)
    }

    public func disconnect() async {
        try? await ssh.close()
    }

    // MARK: - Metadata (POSIX commands over exec)

    public func homeDirectory() async throws -> String {
        let result = try await run("pwd")
        let path = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.exitCode == 0 && !path.isEmpty) ? path : "/"
    }

    public func list(directory path: String, includeHidden: Bool) async throws -> [FileItem] {
        // Honour the notADirectory contract (matches SFTP/local) — `ls` on a
        // file would otherwise return a single bogus "listing".
        let directory = try await stat(path: path)
        guard directory.isDirectory else {
            throw FileSystemSourceError.notADirectory(path: path)
        }
        let result = try await run("ls -la -- \(Self.shellQuote(normalize(path)))")
        guard result.exitCode == 0 else { throw mapCommandError(result, path: path) }
        let text = String(decoding: result.stdout, as: UTF8.self)
        // Reuse the Unix `ls -l` parser (FTP LIST is the same dialect, ADR-020).
        let items = FTPListParser.parse(text, directory: normalize(path))
        return includeHidden ? items : items.filter { !$0.isHidden }
    }

    public func stat(path: String) async throws -> FileItem {
        let normalized = normalize(path)
        // Root has no parent line to parse — synthesize it (matches FTPSource).
        if normalized == "/" {
            return FileItem(name: "/", path: "/", isDirectory: true)
        }
        // `ls -ld` prints one `ls -l` line for the entry itself; its name field
        // is the path we passed, so keep the parsed metadata but restore the
        // real basename/path.
        let result = try await run("ls -ld -- \(Self.shellQuote(normalized))")
        guard result.exitCode == 0 else { throw mapCommandError(result, path: path) }
        let text = String(decoding: result.stdout, as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline)
                .map(String.init)
                .first(where: { !$0.isEmpty && !$0.hasPrefix("total ") }),
              let parsed = FTPListParser.parseLine(line, directory: "/") else {
            throw FileSystemSourceError.notFound(path: path)
        }
        let name = (normalized as NSString).lastPathComponent
        return FileItem(name: name.isEmpty ? "/" : name,
                        path: normalized,
                        isDirectory: parsed.isDirectory,
                        isSymlink: parsed.isSymlink,
                        isHidden: name.hasPrefix("."),
                        size: parsed.isDirectory ? nil : parsed.size,
                        modifiedAt: parsed.modifiedAt,
                        permissions: parsed.permissions,
                        owner: parsed.owner,
                        group: parsed.group)
    }

    /// Creates intermediate directories as needed (protocol contract, `mkdir -p`).
    public func createDirectory(at path: String) async throws {
        if (try? await stat(path: path)) != nil {
            throw FileSystemSourceError.alreadyExists(path: path)
        }
        let result = try await run("mkdir -p -- \(Self.shellQuote(normalize(path)))")
        guard result.exitCode == 0 else { throw mapCommandError(result, path: path) }
    }

    /// Files and directories; directories recursively (`rm -rf`, protocol
    /// contract — the UI confirms first).
    public func delete(at path: String) async throws {
        let result = try await run("rm -rf -- \(Self.shellQuote(normalize(path)))")
        guard result.exitCode == 0 else { throw mapCommandError(result, path: path) }
    }

    /// Refuses to clobber an existing destination (`.alreadyExists`, matching
    /// the other backends) so the UI's conflict flow decides replacements.
    public func rename(from sourcePath: String, to destinationPath: String) async throws {
        if (try? await stat(path: destinationPath)) != nil {
            throw FileSystemSourceError.alreadyExists(path: destinationPath)
        }
        let result = try await run("mv -- \(Self.shellQuote(normalize(sourcePath))) "
                                   + Self.shellQuote(normalize(destinationPath)))
        guard result.exitCode == 0 else { throw mapCommandError(result, path: sourcePath) }
    }

    public func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        let octal = String(permissions.rawMode, radix: 8)
        let result = try await run("chmod \(octal) -- \(Self.shellQuote(normalize(path)))")
        guard result.exitCode == 0 else { throw mapCommandError(result, path: path) }
    }

    // MARK: - Read (scp -f source→sink)

    public func openRead(at path: String, offset: Int64) async throws -> AsyncThrowingStream<Data, Error> {
        guard offset >= 0 else { throw FileSystemSourceError.invalidOffset(offset) }
        let client = ssh
        let command = "scp -f \(Self.shellQuote(normalize(path)))"
        let filePath = path

        return AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                // driveDownload finishes the continuation itself (success or a
                // typed error) and never throws, because Citadel's withExec
                // masks a thrown error with an "Already closed" cleanup error
                // when the remote scp has already exited. Any withExec-level
                // failure that reaches here is a no-op once the continuation is
                // already finished (first finish wins).
                do {
                    try await client.withExec(command) { inbound, outbound in
                        await SCPSource.driveDownload(inbound: inbound, outbound: outbound,
                                                      offset: offset, path: filePath,
                                                      continuation: continuation)
                    }
                } catch {
                    continuation.finish(throwing: SCPSource.mapTransferError(error, path: filePath))
                }
                continuation.finish()
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    /// Drives the scp **sink** side of the classic protocol: ack, read the `C`
    /// header, ack, stream the file bytes (skipping the first `offset` — SCP has
    /// no seek, so a resume re-reads from the start), then ack the trailer. The
    /// outcome is delivered through `continuation`; this never throws.
    @available(macOS 15.0, *)
    private static func driveDownload(inbound: TTYOutput,
                                      outbound: TTYStdinWriter,
                                      offset: Int64,
                                      path: String,
                                      continuation: AsyncThrowingStream<Data, Error>.Continuation) async {
        let reader = SCPByteReader(inbound)
        do {
            try await outbound.write(ByteBuffer(bytes: [0]))   // "ready"
            while let control = try await reader.readLine() {
                guard let first = control.first else { continue }
                switch first {
                case UInt8(ascii: "C"):
                    let size = try parseFileSize(control)
                    try await outbound.write(ByteBuffer(bytes: [0]))   // ack header
                    try await streamData(reader: reader, size: size, offset: offset,
                                         continuation: continuation)
                    try await expectAck(reader)   // trailer: 0 = OK
                    try await outbound.write(ByteBuffer(bytes: [0]))   // ack trailer
                    continuation.finish()
                    return
                case 1, 2:   // scp warning / error — message is the rest of the line
                    continuation.finish(throwing: mapTransferError(scpMessageError(control), path: path))
                    return
                case UInt8(ascii: "T"):
                    try await outbound.write(ByteBuffer(bytes: [0]))   // mtime — ack, ignore
                case UInt8(ascii: "D"):
                    continuation.finish(throwing: FileSystemSourceError.io(
                        "scp returned a directory; SCP fetches single files"))
                    return
                default:
                    continuation.finish(throwing: FileSystemSourceError.io(
                        "unexpected scp control byte \(first)"))
                    return
                }
            }
            // Stream ended before a `C` header — collect stderr for the reason.
            await reader.drainCollectingStderr()
            continuation.finish(throwing: mapTransferError(reader.failure(), path: path))
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            // A write/read failed (often the channel closing after an scp error
            // that landed on stderr) — surface the server's reason if we have it.
            await reader.drainCollectingStderr()
            let mapped = reader.stderr.isEmpty ? error : reader.failure()
            continuation.finish(throwing: mapTransferError(mapped, path: path))
        }
    }

    private static func streamData(reader: SCPByteReader, size: Int64, offset: Int64,
                                   continuation: AsyncThrowingStream<Data, Error>.Continuation) async throws {
        var remaining = size
        var toSkip = max(0, offset)
        while remaining > 0 {
            try Task.checkCancellation()
            let want = Int(min(remaining, Int64(chunkLength)))
            let chunk = try await reader.read(upTo: want)
            if chunk.isEmpty { throw FileSystemSourceError.io("scp stream ended early") }
            remaining -= Int64(chunk.count)
            if toSkip >= Int64(chunk.count) {
                toSkip -= Int64(chunk.count)
            } else if toSkip > 0 {
                continuation.yield(chunk.subdata(in: Int(toSkip)..<chunk.count))
                toSkip = 0
            } else {
                continuation.yield(chunk)
            }
        }
    }

    // MARK: - Write (scp -t sink←source)

    /// SCP declares the file size up front and cannot append, so the write
    /// handle buffers to a local temp file and transfers on `close()`. To keep
    /// interrupted uploads from poisoning the engine's resume (a partial at the
    /// destination would make the retry request a non-zero offset SCP can't
    /// honour), it stages to a remote `.ferry-scp-part` file and renames into
    /// place on success. A non-zero offset is therefore rejected
    /// (DOMAIN.md → SCP): resume restarts cleanly instead.
    public func openWrite(at path: String, offset: Int64) async throws -> any FileWriteHandle {
        guard offset >= 0 else { throw FileSystemSourceError.invalidOffset(offset) }
        guard offset == 0 else { throw FileSystemSourceError.invalidOffset(offset) }
        return try SCPUploadHandle(client: ssh, remotePath: normalize(path))
    }

    // MARK: - Command execution

    struct CommandResult {
        var stdout: Data
        var stderr: Data
        var exitCode: Int
    }

    /// Runs a remote command over an exec channel and collects its output. A
    /// non-zero exit is returned in `CommandResult` (normal for e.g. `ls` on a
    /// missing path); only a transport-level failure throws (as `.io`).
    private func run(_ command: String) async throws -> CommandResult {
        do {
            let stream = try await ssh.executeCommandStream(command)
            var stdout = Data()
            var stderr = Data()
            do {
                for try await chunk in stream {
                    switch chunk {
                    case .stdout(let buffer): stdout.append(Data(buffer.readableBytesView))
                    case .stderr(let buffer): stderr.append(Data(buffer.readableBytesView))
                    }
                }
                return CommandResult(stdout: stdout, stderr: stderr, exitCode: 0)
            } catch let failure as SSHClient.CommandFailed {
                return CommandResult(stdout: stdout, stderr: stderr, exitCode: failure.exitCode)
            }
        } catch {
            throw FileSystemSourceError.io("SSH command failed: \(error)")
        }
    }

    private func mapCommandError(_ result: CommandResult, path: String) -> Error {
        Self.mapCommandText(String(decoding: result.stderr, as: UTF8.self)
                            + String(decoding: result.stdout, as: UTF8.self),
                            exitCode: result.exitCode, path: path)
    }

    // MARK: - Helpers (nonisolated / static)

    /// Collapses redundant slashes and guarantees a leading slash.
    private nonisolated func normalize(_ path: String) -> String {
        "/" + path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    /// Single-quotes an argument for a POSIX shell (sshd runs exec via the login
    /// shell), escaping embedded single quotes. Together with `--` this blocks
    /// command/option injection through file names.
    static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Parses the size from a `C<mode> <size> <name>` scp header line.
    private static func parseFileSize(_ control: [UInt8]) throws -> Int64 {
        let text = String(decoding: control, as: UTF8.self)   // e.g. "C0644 1234 name"
        let fields = text.split(separator: " ", maxSplits: 2)
        guard fields.count >= 2, let size = Int64(fields[1]), size >= 0 else {
            throw FileSystemSourceError.io("malformed scp header: \(text)")
        }
        return size
    }

    /// Reads a single status byte and throws if it isn't 0 (OK).
    @available(macOS 15.0, *)
    private static func expectAck(_ reader: SCPByteReader) async throws {
        guard let status = try await reader.readByte() else {
            throw FileSystemSourceError.io("scp connection closed unexpectedly")
        }
        guard status == 0 else {
            let message = (try? await reader.readLine()).flatMap { $0 } ?? []
            throw mapCommandText(String(decoding: message, as: UTF8.self), exitCode: 1, path: "")
        }
    }

    /// Maps a `\x01`/`\x02` scp message line into a typed error.
    private static func scpMessageError(_ control: [UInt8]) -> Error {
        mapCommandText(String(decoding: control.dropFirst(), as: UTF8.self), exitCode: 1, path: "")
    }

    /// Classifies remote command / scp text (`stderr` and scp status messages
    /// share the same wording) into the FileSystemSource error contract.
    static func mapCommandText(_ text: String, exitCode: Int, path: String) -> Error {
        let lower = text.lowercased()
        if lower.contains("no such file") || lower.contains("not found") {
            return FileSystemSourceError.notFound(path: path)
        }
        if lower.contains("permission denied") || lower.contains("operation not permitted") {
            return FileSystemSourceError.permissionDenied(path: path)
        }
        if lower.contains("file exists") {
            return FileSystemSourceError.alreadyExists(path: path)
        }
        if lower.contains("not a directory") {
            return FileSystemSourceError.notADirectory(path: path)
        }
        let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileSystemSourceError.io(detail.isEmpty ? "command exited with status \(exitCode)" : detail)
    }

    /// Normalizes errors from the scp exec path (protocol errors, channel
    /// failures) into the FileSystemSource contract.
    static func mapTransferError(_ error: Error, path: String) -> Error {
        if error is CancellationError { return error }
        if let sourceError = error as? FileSystemSourceError {
            // Attach the path when the protocol error didn't carry one.
            switch sourceError {
            case .notFound(""): return FileSystemSourceError.notFound(path: path)
            case .permissionDenied(""): return FileSystemSourceError.permissionDenied(path: path)
            case .notADirectory(""): return FileSystemSourceError.notADirectory(path: path)
            case .alreadyExists(""): return FileSystemSourceError.alreadyExists(path: path)
            default: return sourceError
            }
        }
        if error is RemoteSourceError { return error }
        if let failure = error as? SSHClient.CommandFailed {
            return FileSystemSourceError.io("scp exited with status \(failure.exitCode)")
        }
        return FileSystemSourceError.io(String(describing: error))
    }
}

/// Keep-alive + auto-reconnect hooks (ConnectionSupervisor, M9).
@available(macOS 15.0, *)
extension SCPSource: SupervisedConnection {}

// MARK: - scp protocol byte reader

/// Buffers the `stdout` of an scp exec channel and exposes the byte-, line-, and
/// block-oriented reads the classic scp protocol needs. `stderr` is collected on
/// the side for error messages. Single-consumer (the protocol driver).
@available(macOS 15.0, *)
final class SCPByteReader {
    private var iterator: TTYOutput.AsyncIterator
    private var buffer = Data()
    private var index = 0
    private(set) var stderr = Data()

    init(_ inbound: TTYOutput) {
        iterator = inbound.makeAsyncIterator()
    }

    /// Pulls the next stdout chunk into the buffer; false at EOF. stderr chunks
    /// are set aside and skipped.
    private func fill() async throws -> Bool {
        if index == buffer.count {   // fully drained — reclaim memory
            buffer.removeAll(keepingCapacity: true)
            index = 0
        }
        while true {
            guard let output = try await iterator.next() else { return false }
            switch output {
            case .stdout(let chunk):
                if chunk.readableBytes > 0 {
                    buffer.append(Data(chunk.readableBytesView))
                    return true
                }
            case .stderr(let chunk):
                stderr.append(Data(chunk.readableBytesView))
            }
        }
    }

    func readByte() async throws -> UInt8? {
        if index >= buffer.count, !(try await fill()) { return nil }
        let byte = buffer[buffer.startIndex + index]
        index += 1
        return byte
    }

    /// Reads up to and including a newline; returns the line without the `\n`,
    /// or nil at EOF with nothing buffered.
    func readLine() async throws -> [UInt8]? {
        var line: [UInt8] = []
        while let byte = try await readByte() {
            if byte == 0x0A { return line }
            line.append(byte)
        }
        return line.isEmpty ? nil : line
    }

    /// Returns 1...max bytes, or empty `Data` at EOF.
    func read(upTo max: Int) async throws -> Data {
        if index >= buffer.count, !(try await fill()) { return Data() }
        let start = buffer.startIndex + index
        let count = Swift.min(max, buffer.count - index)
        let slice = buffer.subdata(in: start..<(start + count))
        index += count
        return slice
    }

    /// Consumes the remaining stream, gathering any `stderr` the server emitted
    /// (e.g. an scp error that landed on stderr rather than the protocol
    /// stream). Swallows the terminal error/exit — it's only used to build a
    /// diagnostic after a failure.
    func drainCollectingStderr() async {
        while true {
            let output: ExecCommandOutput?
            do { output = try await iterator.next() } catch { return }
            guard let output else { return }
            if case .stderr(let chunk) = output { stderr.append(Data(chunk.readableBytesView)) }
        }
    }

    /// A typed error built from the collected `stderr`.
    func failure() -> Error {
        SCPSource.mapCommandText(String(decoding: stderr, as: UTF8.self), exitCode: 1, path: "")
    }
}

// MARK: - scp upload handle

/// Buffers upload chunks to a local temp file, then transfers the whole file via
/// `scp -t` on `close()` — SCP needs the size declared up front and cannot
/// append. Stages to a remote `.ferry-scp-part` file renamed into place on
/// success, so an interrupted upload never leaves a partial at the destination.
/// `@unchecked Sendable`: the temp writes are serialized on `ioQueue` and
/// `close()` is called exactly once (guarded).
@available(macOS 15.0, *)
final class SCPUploadHandle: FileWriteHandle, @unchecked Sendable {
    private let client: SSHClient
    private let remotePath: String
    private let tempURL: URL
    private let handle: FileHandle
    private let ioQueue = DispatchQueue(label: "com.gfragos.Ferry.scp-upload")
    private let lock = NSLock()
    private var closed = false

    init(client: SSHClient, remotePath: String) throws {
        self.client = client
        self.remotePath = remotePath
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-scp-upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw FileSystemSourceError.io("could not create a local staging file for the upload")
        }
        handle = try FileHandle(forWritingTo: tempURL)
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                do {
                    try self.handle.write(contentsOf: data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: FileSystemSourceError.io("staging write failed: \(error)"))
                }
            }
        }
    }

    private func claimClose() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if closed { return false }
        closed = true
        return true
    }

    func close() async throws {
        guard claimClose() else { return }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try? handle.close()

        let size = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64)
            .flatMap { $0 } ?? 0
        let stagingPath = remotePath + SCPSource.uploadStagingSuffix
        let name = (stagingPath as NSString).lastPathComponent
        let dataURL = tempURL

        // driveUpload records its outcome out-of-band and never throws through
        // withExec, whose cleanup would otherwise mask the real protocol error
        // (or falsely fail a successful upload) with "Already closed" once the
        // remote scp has exited. See the download path for the same reason.
        let outcome = UploadOutcome()
        var channelError: Error?
        do {
            try await client.withExec("scp -t \(SCPSource.shellQuote(stagingPath))") { inbound, outbound in
                await SCPUploadHandle.driveUpload(inbound: inbound, outbound: outbound,
                                                  size: size, name: name, dataURL: dataURL,
                                                  outcome: outcome)
            }
        } catch {
            channelError = error
        }
        if let error = outcome.error {
            throw SCPSource.mapTransferError(error, path: remotePath)
        }
        guard outcome.completed else {
            throw SCPSource.mapTransferError(
                channelError ?? FileSystemSourceError.io("scp upload did not complete"),
                path: remotePath)
        }
        // Move the fully-received staging file into place (same directory →
        // atomic). `mv -f` overwrites a prior file the user chose to replace.
        let move = try await moveIntoPlace(from: stagingPath, to: remotePath)
        guard move.exitCode == 0 else {
            throw SCPSource.mapCommandText(String(decoding: move.stderr, as: UTF8.self),
                                           exitCode: move.exitCode, path: remotePath)
        }
    }

    private func moveIntoPlace(from stagingPath: String, to finalPath: String) async throws -> SCPSource.CommandResult {
        let command = "mv -f -- \(SCPSource.shellQuote(stagingPath)) \(SCPSource.shellQuote(finalPath))"
        let stream = try await client.executeCommandStream(command)
        var stderr = Data()
        do {
            for try await chunk in stream {
                if case .stderr(let buffer) = chunk { stderr.append(Data(buffer.readableBytesView)) }
            }
            return SCPSource.CommandResult(stdout: Data(), stderr: stderr, exitCode: 0)
        } catch let failure as SSHClient.CommandFailed {
            return SCPSource.CommandResult(stdout: Data(), stderr: stderr, exitCode: failure.exitCode)
        }
    }

    /// Drives the scp **source** side: read ack, send the `C` header, read ack,
    /// stream the staged bytes, send the trailer `\0`, read the final ack. The
    /// result is recorded in `outcome`; this never throws (see `close`).
    static func driveUpload(inbound: TTYOutput, outbound: TTYStdinWriter,
                            size: Int64, name: String, dataURL: URL,
                            outcome: UploadOutcome) async {
        let reader = SCPByteReader(inbound)
        do {
            try await SCPUploadHandle.expectAck(reader)
            try await outbound.write(ByteBuffer(string: "C0644 \(size) \(name)\n"))
            try await SCPUploadHandle.expectAck(reader)

            let source = try FileHandle(forReadingFrom: dataURL)
            defer { try? source.close() }
            while true {
                try Task.checkCancellation()
                let chunk = try source.read(upToCount: SCPSource.chunkLength) ?? Data()
                if chunk.isEmpty { break }
                try await outbound.write(ByteBuffer(bytes: chunk))
            }
            try await outbound.write(ByteBuffer(bytes: [0]))   // end of file
            try await SCPUploadHandle.expectAck(reader)
            outcome.completed = true
        } catch is CancellationError {
            outcome.error = CancellationError()
        } catch {
            await reader.drainCollectingStderr()
            outcome.error = reader.stderr.isEmpty ? error : reader.failure()
        }
    }

    private static func expectAck(_ reader: SCPByteReader) async throws {
        guard let status = try await reader.readByte() else {
            throw FileSystemSourceError.io("scp connection closed unexpectedly")
        }
        guard status == 0 else {
            let message = (try? await reader.readLine()).flatMap { $0 } ?? []
            throw SCPSource.mapCommandText(String(decoding: message, as: UTF8.self), exitCode: 1, path: "")
        }
    }
}

/// Out-of-band result of an scp upload protocol run, so the driver need not
/// throw through Citadel's withExec (whose cleanup masks the real error).
@available(macOS 15.0, *)
final class UploadOutcome: @unchecked Sendable {
    var completed = false
    var error: Error?
}
