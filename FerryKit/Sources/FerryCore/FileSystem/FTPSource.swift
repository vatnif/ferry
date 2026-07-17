import CFTP
import Foundation

/// TLS posture for an FTP connection (DOMAIN.md → FTP, ADR-019).
public enum FTPSecurity: Sendable, Equatable {
    /// Plain FTP, no encryption.
    case none
    /// Explicit FTPS: connect in the clear, then `AUTH TLS` upgrades the
    /// control and data channels (`CURLUSESSL_ALL`). The modern default.
    case explicit
    /// Implicit FTPS: TLS from the first byte on a dedicated port (usually
    /// 990) — the legacy `ftps://` scheme.
    case implicit
}

/// A `FileSystemSource` over FTP / FTPS, backed by the system libcurl
/// (ADR-003/ADR-019 — nothing is bundled). Unlike SFTP there is no persistent
/// session object: FTP's control connection can't multiplex, so every
/// operation drives its own libcurl "easy" handle (its own control + data
/// connection). That keeps concurrent transfers trivially correct — each runs
/// on its own handle and thread — at the cost of a login per operation, which
/// is acceptable for v1 (connection pooling via a share handle is a backlog
/// item). libcurl's blocking `curl_easy_perform` always runs on a detached
/// thread so the actor's executor is never blocked.
public actor FTPSource: FileSystemSource {
    /// Everything needed to build a configured handle; held in memory only,
    /// never logged or persisted (the password especially — DOMAIN.md).
    private struct Parameters: Sendable {
        var host: String
        var port: Int
        var username: String
        var password: String
        var security: FTPSecurity
        /// Skip TLS peer/host verification. Off by default (verify against the
        /// system trust store); tests set it for the self-signed test server.
        /// A proper certificate-trust prompt is a backlog item (ADR-019).
        var allowInvalidCertificate: Bool
    }

    public nonisolated let displayName: String
    private let parameters: Parameters

    /// libcurl requires a one-time global init before any handle is created;
    /// `curl_global_init` is not thread-safe, so a `static let` (evaluated once)
    /// is the right home for it.
    private static let globalInit: Void = { ferry_global_init() }()

    private init(displayName: String, parameters: Parameters) {
        self.displayName = displayName
        self.parameters = parameters
    }

    /// Establishes (really: validates) an FTP session by probing the login with
    /// a `PWD`. Throws `RemoteSourceError.authenticationFailed` on bad
    /// credentials, `.tlsFailed` when the FTPS handshake fails, and
    /// `.connectionFailed` otherwise. The returned source reconnects per
    /// operation, so this is purely an upfront credential/TLS check that also
    /// warms the home directory.
    public static func connect(host: String,
                               port: Int,
                               username: String,
                               password: String,
                               security: FTPSecurity,
                               allowInvalidCertificate: Bool = false,
                               displayName: String? = nil) async throws -> FTPSource {
        _ = globalInit
        let parameters = Parameters(host: host, port: port, username: username,
                                    password: password, security: security,
                                    allowInvalidCertificate: allowInvalidCertificate)
        let source = FTPSource(displayName: displayName ?? host, parameters: parameters)
        _ = try await source.currentDirectory()   // probe: classifies auth/TLS/connect errors
        return source
    }

    // MARK: - FileSystemSource

    public func homeDirectory() async throws -> String {
        (try? await currentDirectory()) ?? "/"
    }

    public func list(directory path: String, includeHidden: Bool) async throws -> [FileItem] {
        let easy = makeHandle(url: url(forPath: path, isDirectory: true), collecting: true)
        let outcome = try await perform(easy)
        try throwIfFailed(outcome, path: path)
        let text = String(decoding: outcome.body, as: UTF8.self)
        let items = FTPListParser.parse(text, directory: normalizedDirectory(path))
        return includeHidden ? items : items.filter { !$0.isHidden }
    }

    public func stat(path: String) async throws -> FileItem {
        let normalized = normalize(path)
        // Root has no parent to list — synthesize it.
        if normalized == "/" {
            return FileItem(name: "/", path: "/", isDirectory: true)
        }
        // FTP has no stat; find the entry in its parent's listing (the LIST
        // line carries type/size/perms/owner — everything FileItem needs).
        let parent = (normalized as NSString).deletingLastPathComponent
        let name = (normalized as NSString).lastPathComponent
        let siblings = try await list(directory: parent.isEmpty ? "/" : parent, includeHidden: true)
        guard let match = siblings.first(where: { $0.name == name }) else {
            throw FileSystemSourceError.notFound(path: path)
        }
        return match
    }

    public func createDirectory(at path: String) async throws {
        if (try? await stat(path: path)) != nil {
            throw FileSystemSourceError.alreadyExists(path: path)
        }
        // MKD is single-level; create missing ancestors root-down (matches the
        // SFTPSource contract). Tolerate an ancestor that already exists.
        var current = ""
        for component in normalize(path).split(separator: "/") {
            current += "/" + component
            if (try? await stat(path: current)) != nil { continue }
            try await runQuote(["MKD " + current], referenceDirectory: current, path: current)
        }
    }

    public func delete(at path: String) async throws {
        let item = try await stat(path: path)
        let normalized = normalize(path)
        if item.isDirectory {
            for child in try await list(directory: normalized, includeHidden: true) {
                try await delete(at: child.path)
            }
            try await runQuote(["RMD " + normalized], referenceDirectory: normalized, path: path)
        } else {
            try await runQuote(["DELE " + normalized], referenceDirectory: normalized, path: path)
        }
    }

    /// Refuses to clobber an existing destination (`.alreadyExists`, matching
    /// the other backends) so the UI's conflict flow decides replacements.
    public func rename(from sourcePath: String, to destinationPath: String) async throws {
        if (try? await stat(path: destinationPath)) != nil {
            throw FileSystemSourceError.alreadyExists(path: destinationPath)
        }
        let from = normalize(sourcePath)
        let to = normalize(destinationPath)
        // RNFR then RNTO must run as a pair on one connection (RNTO depends on
        // the preceding RNFR) — libcurl sends the quote list in order.
        try await runQuote(["RNFR " + from, "RNTO " + to], referenceDirectory: from, path: sourcePath)
    }

    public func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        let normalized = normalize(path)
        let octal = String(permissions.rawMode, radix: 8)
        // SITE CHMOD is a de-facto standard (vsftpd, proftpd); servers that
        // lack it surface a quote error, mapped to `.unsupported`.
        try await runQuote(["SITE CHMOD \(octal) \(normalized)"],
                           referenceDirectory: normalized, path: path)
    }

    public func openRead(at path: String, offset: Int64) async throws -> AsyncThrowingStream<Data, Error> {
        guard offset >= 0 else { throw FileSystemSourceError.invalidOffset(offset) }
        let easy = makeHandle(url: url(forPath: path, isDirectory: false), collecting: false)
        if offset > 0 { easy.setResumeFrom(offset) }
        let filePath = path

        return AsyncThrowingStream(Data.self) { continuation in
            let box = DownloadBox(continuation: continuation)
            easy.download = box
            ferry_set_write_cb(easy.handle, ftpDownloadWriteCallback, box.opaque())
            continuation.onTermination = { termination in
                if case .cancelled = termination { box.cancel() }
            }
            Thread.detachNewThread {
                let code = easy.performRaw()
                if code == curlOK || box.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: FTPSource.mapError(
                        code: code, responseCode: easy.responseCode(),
                        errorText: easy.errorText(), path: filePath))
                }
                easy.download = nil   // release the box
            }
        }
    }

    public func openWrite(at path: String, offset: Int64) async throws -> any FileWriteHandle {
        guard offset >= 0 else { throw FileSystemSourceError.invalidOffset(offset) }

        let easy = makeHandle(url: url(forPath: path, isDirectory: false), collecting: false)
        easy.setUpload()
        if offset > 0 {
            // FTP can't truncate, so resume requires the remote size to match
            // the offset exactly (the engine computes offset = remote size).
            let existing = try await stat(path: path)
            guard existing.size == offset else { throw FileSystemSourceError.invalidOffset(offset) }
            easy.setAppend()
        }

        let handle = FTPUploadHandle()
        easy.upload = handle
        ferry_set_read_cb(easy.handle, ftpUploadReadCallback, handle.opaque())
        let filePath = path
        Thread.detachNewThread {
            let code = easy.performRaw()
            let error: Error? = (code == curlOK) ? nil : FTPSource.mapError(
                code: code, responseCode: easy.responseCode(),
                errorText: easy.errorText(), path: filePath)
            handle.finish(error: error)
            easy.upload = nil
        }
        return handle
    }

    // MARK: - SupervisedConnection (keep-alive / auto-reconnect, M9)

    /// FTP has no long-lived session, so a "ping" is a fresh `PWD` probe — it
    /// still proves the server is reachable and the credentials work.
    public func ping() async throws {
        _ = try await currentDirectory()
    }

    /// Nothing persistent to rebuild; a successful probe means "reconnected".
    public func reestablish() async throws {
        _ = try await currentDirectory()
    }

    public func disconnect() async {
        // No persistent connection to close.
    }

    // MARK: - Control helpers

    /// Runs `PWD` and parses the `257 "<path>"` reply from the control channel.
    private func currentDirectory() async throws -> String {
        let easy = makeHandle(url: baseURL(), collecting: true)
        easy.setNoBody()
        easy.setQuote(["PWD"])
        let outcome = try await perform(easy)
        try throwConnectErrorIfFailed(outcome)
        for line in outcome.header {
            // e.g. `257 "/home/ferry" is the current directory`
            if line.hasPrefix("257"), let open = line.firstIndex(of: "\""),
               let close = line[line.index(after: open)...].firstIndex(of: "\"") {
                let path = String(line[line.index(after: open)..<close])
                return path.isEmpty ? "/" : path
            }
        }
        return "/"
    }

    /// Runs one or more raw FTP commands via `CURLOPT_QUOTE` against a NOBODY
    /// transfer. `path` is used only for error messages.
    private func runQuote(_ commands: [String], referenceDirectory: String, path: String) async throws {
        // A CR/LF in a path would split into a second, smuggled FTP command on
        // the control channel — reject it rather than inject it.
        for command in commands where command.contains("\r") || command.contains("\n") {
            throw FileSystemSourceError.io("illegal control character in path")
        }
        let easy = makeHandle(url: baseURL(), collecting: true)
        easy.setNoBody()
        easy.setQuote(commands)
        let outcome = try await perform(easy)
        try throwIfFailed(outcome, path: path)
    }

    // MARK: - Handle construction

    private func makeHandle(url: String, collecting: Bool) -> CurlEasy {
        let easy = CurlEasy()
        easy.setString(CURLOPT_URL, url)
        easy.setLong(CURLOPT_PORT, parameters.port)
        easy.setString(CURLOPT_USERNAME, parameters.username)
        easy.setString(CURLOPT_PASSWORD, parameters.password)
        easy.setLong(CURLOPT_CONNECTTIMEOUT, 30)
        // Backstop for a silently-dead connection: abort a transfer stuck below
        // 1 byte/s for 60 s. This bounds how long a stalled perform (and thus a
        // pending cancel that can only take effect on the next callback) can
        // block its detached thread; genuine throughput never trips it.
        easy.setLong(CURLOPT_LOW_SPEED_LIMIT, 1)
        easy.setLong(CURLOPT_LOW_SPEED_TIME, 60)
        easy.setLong(CURLOPT_NOSIGNAL, 1)
        // Docker/NAT servers often advertise an unroutable PASV IP — reuse the
        // control connection's address instead.
        easy.setLong(CURLOPT_FTP_SKIP_PASV_IP, 1)
        switch parameters.security {
        case .none:
            break
        case .explicit:
            easy.setLong(CURLOPT_USE_SSL, ferry_usessl_all())
        case .implicit:
            break   // the ftps:// scheme already implies TLS from the first byte
        }
        if parameters.security != .none, parameters.allowInvalidCertificate {
            easy.setLong(CURLOPT_SSL_VERIFYPEER, 0)
            easy.setLong(CURLOPT_SSL_VERIFYHOST, 0)
        }
        if collecting {
            let box = CollectBox()
            easy.collect = box
            ferry_set_write_cb(easy.handle, ftpBodyCollectCallback, box.opaque())
            ferry_set_header_cb(easy.handle, ftpHeaderCollectCallback, box.opaque())
        }
        return easy
    }

    /// Awaits `curl_easy_perform` on a detached thread, then reads the handle's
    /// collected body/headers and result codes back on the actor.
    private func perform(_ easy: CurlEasy) async throws -> Outcome {
        let code: CURLcode = await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: easy.performRaw()) }
        }
        return Outcome(code: code,
                       responseCode: easy.responseCode(),
                       body: easy.collect?.body ?? Data(),
                       header: easy.collect?.header ?? [],
                       errorText: easy.errorText())
    }

    private struct Outcome {
        var code: CURLcode
        var responseCode: Int
        var body: Data
        var header: [String]
        var errorText: String
    }

    private func throwIfFailed(_ outcome: Outcome, path: String) throws {
        guard outcome.code != curlOK else { return }
        throw Self.mapError(code: outcome.code, responseCode: outcome.responseCode,
                            errorText: outcome.errorText, path: path)
    }

    private func throwConnectErrorIfFailed(_ outcome: Outcome) throws {
        guard outcome.code != curlOK else { return }
        throw Self.mapConnectError(code: outcome.code, responseCode: outcome.responseCode,
                                   errorText: outcome.errorText)
    }

    // MARK: - URL building

    private var schemePrefix: String {
        parameters.security == .implicit ? "ftps" : "ftp"
    }

    private func baseURL() -> String {
        "\(schemePrefix)://\(parameters.host):\(parameters.port)/"
    }

    /// Builds the libcurl URL for an absolute remote path. libcurl treats a
    /// URL path as *relative to the login directory*; a leading slash encoded
    /// as `%2F` is the documented way to anchor at the server root — which is
    /// where Ferry's absolute paths live.
    private func url(forPath path: String, isDirectory: Bool) -> String {
        let trimmed = normalize(path).drop(while: { $0 == "/" })
        let encoded = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { Self.encodeSegment(String($0)) }
            .joined(separator: "/")
        var result = "\(schemePrefix)://\(parameters.host):\(parameters.port)/%2F\(encoded)"
        if isDirectory, !result.hasSuffix("/") { result += "/" }
        return result
    }

    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~!$&'()*+,;=:@")
        return set
    }()

    private static func encodeSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? segment
    }

    /// Collapses redundant slashes and guarantees a leading slash.
    private func normalize(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + components.joined(separator: "/")
    }

    private func normalizedDirectory(_ path: String) -> String {
        normalize(path)
    }

    // MARK: - Error mapping

    /// Maps a libcurl result into the FileSystemSource error contract. FTP
    /// leans on the numeric reply code (550 = no such file / no access, 553 =
    /// name not allowed) since `CURLE_QUOTE_ERROR` alone is generic.
    static func mapError(code: CURLcode, responseCode: Int, errorText: String, path: String) -> Error {
        switch code {
        case CURLE_REMOTE_FILE_NOT_FOUND, CURLE_TFTP_NOTFOUND:
            return FileSystemSourceError.notFound(path: path)
        case CURLE_REMOTE_ACCESS_DENIED, CURLE_LOGIN_DENIED:
            return FileSystemSourceError.permissionDenied(path: path)
        case CURLE_QUOTE_ERROR, CURLE_FTP_COULDNT_RETR_FILE:
            switch responseCode {
            case 550: return FileSystemSourceError.notFound(path: path)
            case 553: return FileSystemSourceError.permissionDenied(path: path)
            case 500, 502: return FileSystemSourceError.unsupported(operation: "the server rejected this command")
            default: return FileSystemSourceError.io(detail(errorText, code))
            }
        default:
            return FileSystemSourceError.io(detail(errorText, code))
        }
    }

    /// Maps a libcurl result at connect time into `RemoteSourceError`.
    static func mapConnectError(code: CURLcode, responseCode: Int, errorText: String) -> RemoteSourceError {
        switch code {
        case CURLE_LOGIN_DENIED, CURLE_REMOTE_ACCESS_DENIED:
            return .authenticationFailed
        case CURLE_USE_SSL_FAILED, CURLE_SSL_CONNECT_ERROR, CURLE_PEER_FAILED_VERIFICATION,
             CURLE_SSL_CACERT, CURLE_SSL_CIPHER, CURLE_SSL_CERTPROBLEM:
            return .tlsFailed(detail(errorText, code))
        default:
            if responseCode == 530 { return .authenticationFailed }
            return .connectionFailed(detail(errorText, code))
        }
    }

    private static func detail(_ errorText: String, _ code: CURLcode) -> String {
        if !errorText.isEmpty { return errorText }
        return String(cString: curl_easy_strerror(code))
    }
}

/// Keep-alive + auto-reconnect hooks (ConnectionSupervisor, M9).
extension FTPSource: SupervisedConnection {}

// MARK: - libcurl easy-handle wrapper

private let curlOK = CURLE_OK

/// Owns one `CURL *` for the lifetime of a single operation. `@unchecked
/// Sendable` because it is handed to exactly one detached thread at a time
/// (the actor never touches the handle while `perform` is in flight), and the
/// callback boxes it retains are themselves thread-safe.
private final class CurlEasy: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer
    private var errorBuffer: [CChar]
    private var quoteList: UnsafeMutablePointer<curl_slist>?

    // Strong references keep the callback context alive for the transfer.
    var collect: CollectBox?
    var download: DownloadBox?
    var upload: FTPUploadHandle?

    init() {
        handle = curl_easy_init()
        errorBuffer = [CChar](repeating: 0, count: Int(ferry_error_size()))
        errorBuffer.withUnsafeMutableBufferPointer { _ = ferry_set_errorbuffer(handle, $0.baseAddress) }
    }

    deinit {
        if let quoteList { curl_slist_free_all(quoteList) }
        curl_easy_cleanup(handle)
    }

    func setLong(_ option: CURLoption, _ value: Int) { _ = ferry_setopt_long(handle, option, value) }
    func setLong(_ option: CURLoption, _ value: Int32) { _ = ferry_setopt_long(handle, option, Int(value)) }
    func setString(_ option: CURLoption, _ value: String) { _ = ferry_setopt_string(handle, option, value) }

    func setNoBody() { setLong(CURLOPT_NOBODY, 1) }
    func setUpload() { setLong(CURLOPT_UPLOAD, 1) }
    func setAppend() { setLong(CURLOPT_APPEND, 1) }
    func setResumeFrom(_ offset: Int64) { _ = ferry_setopt_off(handle, CURLOPT_RESUME_FROM_LARGE, curl_off_t(offset)) }

    func setQuote(_ commands: [String]) {
        var list: UnsafeMutablePointer<curl_slist>?
        for command in commands { list = curl_slist_append(list, command) }
        quoteList = list
        _ = ferry_setopt_slist(handle, CURLOPT_QUOTE, list)
    }

    func performRaw() -> CURLcode { curl_easy_perform(handle) }

    func responseCode() -> Int {
        var code: Int = 0
        _ = ferry_getinfo_long(handle, CURLINFO_RESPONSE_CODE, &code)
        return code
    }

    func errorText() -> String {
        errorBuffer.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, base.pointee != 0 else { return "" }
            return String(cString: base)
        }
    }
}

// MARK: - Callback context boxes

/// Accumulates a control op's response body and control-channel header lines.
private final class CollectBox: @unchecked Sendable {
    var body = Data()
    var header: [String] = []
    func opaque() -> UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
}

/// Bridges libcurl's push-model download callback (called on the perform
/// thread) to an `AsyncThrowingStream`.
private final class DownloadBox: @unchecked Sendable {
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var cancelled = false

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func opaque() -> UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
}

/// Bridges the engine's push-model `write`/`close` to libcurl's pull-model
/// upload read callback (called on the perform thread), with bounded buffering
/// for backpressure. `@unchecked Sendable`: all state is guarded by `cond`.
private final class FTPUploadHandle: FileWriteHandle, @unchecked Sendable {
    private let cond = NSCondition()
    private var pending = Data()
    private var producerDone = false
    private var finished = false
    private var failure: Error?
    private var completion: CheckedContinuation<Void, Error>?
    private let highWater = 512 * 1024
    /// Hosts write()'s blocking enqueue off the cooperative executor. One
    /// serial queue (not a fresh thread per chunk) — writes are sequential.
    private let ioQueue = DispatchQueue(label: "com.gfragos.Ferry.ftp-upload")

    func opaque() -> UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// Called by the engine (off the actor). Blocks — on a non-cooperative
    /// thread — while the buffer is full, so a fast source can't outrun a slow
    /// upload and balloon memory.
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                self.cond.lock()
                while self.pending.count >= self.highWater, self.failure == nil, !self.finished {
                    self.cond.wait()
                }
                if let failure = self.failure {
                    self.cond.unlock()
                    continuation.resume(throwing: failure)
                    return
                }
                self.pending.append(data)
                self.cond.signal()
                self.cond.unlock()
                continuation.resume()
            }
        }
    }

    /// Signals EOF and waits for `curl_easy_perform` to finish, surfacing any
    /// transfer error. Safe to call after a failure (ADR-013 force-close).
    func close() async throws {
        // All NSCondition calls stay inside this synchronous closure — the lock
        // is never held across a suspension point.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            cond.lock()
            producerDone = true
            cond.signal()
            if finished {
                let failure = self.failure
                cond.unlock()
                if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
                return
            }
            completion = continuation
            cond.unlock()
        }
    }

    /// libcurl read callback: fill up to `capacity` bytes; 0 signals EOF.
    func provide(into buffer: UnsafeMutableRawPointer, capacity: Int) -> Int {
        cond.lock()
        while pending.isEmpty, !producerDone, failure == nil { cond.wait() }
        if pending.isEmpty {
            cond.unlock()
            return 0   // EOF (producer closed) — curl completes the STOR/APPE
        }
        let n = min(capacity, pending.count)
        guard n > 0 else { cond.unlock(); return 0 }
        pending.prefix(n).withUnsafeBytes { raw in
            buffer.copyMemory(from: raw.baseAddress!, byteCount: n)
        }
        pending.removeFirst(n)
        cond.signal()   // wake a writer blocked on the high-water mark
        cond.unlock()
        return n
    }

    /// Called from the perform thread when the transfer ends.
    func finish(error: Error?) {
        cond.lock()
        finished = true
        failure = error
        let continuation = completion
        completion = nil
        cond.signal()
        cond.unlock()
        if let continuation {
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }
}

// MARK: - C callbacks (no captures → convertible to @convention(c))

private let ftpBodyCollectCallback: ferry_io_cb = { buffer, size, nitems, userdata in
    let count = size * nitems
    guard count > 0, let buffer, let userdata else { return count }
    let box = Unmanaged<CollectBox>.fromOpaque(userdata).takeUnretainedValue()
    box.body.append(Data(bytes: buffer, count: count))
    return count
}

private let ftpHeaderCollectCallback: ferry_io_cb = { buffer, size, nitems, userdata in
    let count = size * nitems
    guard count > 0, let buffer, let userdata else { return count }
    let box = Unmanaged<CollectBox>.fromOpaque(userdata).takeUnretainedValue()
    let line = String(decoding: UnsafeRawBufferPointer(start: buffer, count: count), as: UTF8.self)
    box.header.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")))
    return count
}

private let ftpDownloadWriteCallback: ferry_io_cb = { buffer, size, nitems, userdata in
    let count = size * nitems
    guard let userdata else { return 0 }
    let box = Unmanaged<DownloadBox>.fromOpaque(userdata).takeUnretainedValue()
    if box.isCancelled { return 0 }   // returning short aborts the transfer
    guard count > 0, let buffer else { return count }
    box.continuation.yield(Data(bytes: buffer, count: count))
    return count
}

private let ftpUploadReadCallback: ferry_io_cb = { buffer, size, nitems, userdata in
    guard let buffer, let userdata else { return 0 }
    let handle = Unmanaged<FTPUploadHandle>.fromOpaque(userdata).takeUnretainedValue()
    return handle.provide(into: UnsafeMutableRawPointer(buffer), capacity: size * nitems)
}
