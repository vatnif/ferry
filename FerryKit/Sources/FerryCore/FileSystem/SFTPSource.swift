@preconcurrency import Citadel
import Foundation
import NIOCore

/// Errors surfaced while establishing a remote session (before the
/// FileSystemSource contract applies).
public enum RemoteSourceError: Error, Equatable {
    case authenticationFailed
    case connectionFailed(String)
}

/// FileSystemSource over SFTP via Citadel (ADR-011). Read side since M6,
/// writes since M8, mkdir + reconnect support since M9, rename + chmod
/// since M10 — the full mutation surface is now live.
///
/// Host keys are currently accepted blindly — M11 replaces the validator
/// with the TOFU flow (HostKeyStore + prompt, DOMAIN.md → Host key trust).
public actor SFTPSource: FileSystemSource {
    /// Everything needed to rebuild the transport for auto-reconnect (M9).
    /// Held in memory only — never logged or persisted (DOMAIN.md).
    private struct Parameters {
        var host: String
        var port: Int
        var username: String
        var password: String
    }

    public nonisolated let displayName: String
    private var ssh: SSHClient
    private var sftp: SFTPClient
    private let parameters: Parameters

    static let readChunkLength: UInt32 = 128 * 1024

    private init(displayName: String, ssh: SSHClient, sftp: SFTPClient, parameters: Parameters) {
        self.displayName = displayName
        self.ssh = ssh
        self.sftp = sftp
        self.parameters = parameters
    }

    /// Password-authenticated connect (key/agent auth arrives in M11).
    public static func connect(host: String,
                               port: Int = 22,
                               username: String,
                               password: String,
                               displayName: String? = nil) async throws -> SFTPSource {
        let parameters = Parameters(host: host, port: port, username: username, password: password)
        let (ssh, sftp) = try await establish(parameters)
        return SFTPSource(displayName: displayName ?? host, ssh: ssh, sftp: sftp,
                          parameters: parameters)
    }

    private static func establish(_ parameters: Parameters) async throws -> (SSHClient, SFTPClient) {
        let ssh: SSHClient
        do {
            ssh = try await SSHClient.connect(
                host: parameters.host,
                port: parameters.port,
                authenticationMethod: .passwordBased(username: parameters.username,
                                                     password: parameters.password),
                hostKeyValidator: .acceptAnything(), // TODO(M11): TOFU via HostKeyStore
                reconnect: .never)
        } catch is Citadel.AuthenticationFailed {
            throw RemoteSourceError.authenticationFailed
        } catch SSHClientError.allAuthenticationOptionsFailed {
            throw RemoteSourceError.authenticationFailed
        } catch {
            throw RemoteSourceError.connectionFailed(String(describing: error))
        }

        do {
            return (ssh, try await ssh.openSFTP())
        } catch {
            try? await ssh.close()
            throw RemoteSourceError.connectionFailed(String(describing: error))
        }
    }

    public func disconnect() async {
        try? await sftp.close()
        try? await ssh.close()
    }

    // MARK: SupervisedConnection (M9 keep-alive + auto-reconnect)

    /// Protocol-level no-op proving the connection is alive.
    public func ping() async throws {
        _ = try await sftp.getRealPath(atPath: ".")
    }

    /// Tears down the dead transport and rebuilds it with the original
    /// parameters. In-flight operations on the old channels fail; the
    /// TransferEngine's retry policy resumes them on the new transport.
    public func reestablish() async throws {
        try? await sftp.close()
        try? await ssh.close()
        let (ssh, sftp) = try await Self.establish(parameters)
        self.ssh = ssh
        self.sftp = sftp
    }

    // MARK: Read operations (M6)

    public func homeDirectory() async throws -> String {
        try await mapped(path: ".") { try await self.sftp.getRealPath(atPath: ".") }
    }

    public func list(directory path: String, includeHidden: Bool) async throws -> [FileItem] {
        let directory = try await stat(path: path)
        guard directory.isDirectory else {
            throw FileSystemSourceError.notADirectory(path: path)
        }
        let names = try await mapped(path: path) { try await self.sftp.listDirectory(atPath: path) }
        return names.flatMap(\.components).compactMap { component in
            guard component.filename != ".", component.filename != ".." else { return nil }
            let item = Self.fileItem(name: component.filename,
                                     fullPath: Self.join(path, component.filename),
                                     attributes: component.attributes,
                                     longname: component.longname)
            return (includeHidden || !item.isHidden) ? item : nil
        }
    }

    public func stat(path: String) async throws -> FileItem {
        let attributes = try await mapped(path: path) { try await self.sftp.getAttributes(at: path) }
        let name = (path as NSString).lastPathComponent
        return Self.fileItem(name: name.isEmpty ? "/" : name,
                             fullPath: path,
                             attributes: attributes,
                             longname: nil)
    }

    public func openRead(at path: String, offset: Int64) async throws -> AsyncThrowingStream<Data, Error> {
        guard offset >= 0 else { throw FileSystemSourceError.invalidOffset(offset) }
        let file = try await mapped(path: path) {
            try await self.sftp.openFile(filePath: path, flags: .read)
        }

        // Unbounded buffering — see LocalFileSource.openRead rationale.
        return AsyncThrowingStream(Data.self) { continuation in
            let task = Task {
                var position = UInt64(offset)
                do {
                    while true {
                        try Task.checkCancellation()
                        let buffer = try await file.read(from: position, length: Self.readChunkLength)
                        let count = buffer.readableBytes
                        if count == 0 { break } // Citadel maps SFTP EOF to an empty buffer
                        position += UInt64(count)
                        continuation.yield(Data(buffer.readableBytesView))
                    }
                    try await file.close()
                    continuation.finish()
                } catch {
                    _ = try? await file.close()
                    continuation.finish(throwing: Self.mapError(error, path: path))
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    // MARK: Write side (M8) + mkdir (M9)

    public func openWrite(at path: String, offset: Int64) async throws -> any FileWriteHandle {
        guard offset >= 0 else { throw FileSystemSourceError.invalidOffset(offset) }

        if offset == 0 {
            let file = try await mapped(path: path) {
                try await self.sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
            }
            return SFTPFileWriteHandle(file: file, position: 0)
        }

        // Resume contract: target must exist (else notFound) with size ≥
        // offset; shrink to offset (SFTP truncates via setstat), then append.
        let attributes = try await mapped(path: path) { try await self.sftp.getAttributes(at: path) }
        guard let size = attributes.size, size >= UInt64(offset) else {
            throw FileSystemSourceError.invalidOffset(offset)
        }
        if size > UInt64(offset) {
            try await mapped(path: path) {
                try await self.sftp.setAttributes(at: path, to: .init(size: UInt64(offset)))
            }
        }
        let file = try await mapped(path: path) {
            try await self.sftp.openFile(filePath: path, flags: [.write])
        }
        return SFTPFileWriteHandle(file: file, position: UInt64(offset))
    }

    /// Files and directories; directories recursively (protocol contract).
    public func delete(at path: String) async throws {
        let item = try await stat(path: path)
        if item.isDirectory {
            for child in try await list(directory: path, includeHidden: true) {
                try await delete(at: child.path)
            }
            try await mapped(path: path) { try await self.sftp.rmdir(at: path) }
        } else {
            try await mapped(path: path) { try await self.sftp.remove(at: path) }
        }
    }

    /// Creates intermediate directories as needed (protocol contract) —
    /// SFTP mkdir itself is single-level, so missing ancestors are created
    /// root-down. Pulled forward from M10 for M9 folder transfers.
    public func createDirectory(at path: String) async throws {
        if (try? await stat(path: path)) != nil {
            throw FileSystemSourceError.alreadyExists(path: path)
        }
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            if (try? await stat(path: current)) != nil { continue }
            let directory = current
            try await mapped(path: directory) {
                try await self.sftp.createDirectory(atPath: directory)
            }
        }
    }

    // MARK: Mutations (rename + chmod, M10)

    /// Rename or move within the source. Refuses to clobber an existing
    /// destination (matches LocalFileSource: `.alreadyExists`) — the UI's
    /// conflict flow, not a silent overwrite, decides replacements.
    public func rename(from sourcePath: String, to destinationPath: String) async throws {
        if (try? await stat(path: destinationPath)) != nil {
            throw FileSystemSourceError.alreadyExists(path: destinationPath)
        }
        try await mapped(path: sourcePath) {
            try await self.sftp.rename(at: sourcePath, to: destinationPath)
        }
    }

    public func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        var attributes = SFTPFileAttributes()
        attributes.permissions = UInt32(permissions.rawMode)
        try await mapped(path: path) {
            try await self.sftp.setAttributes(at: path, to: attributes)
        }
    }

    // MARK: Internals

    /// Sequential SFTP writer. @unchecked Sendable per the FileWriteHandle
    /// contract (no concurrent use of one handle).
    final class SFTPFileWriteHandle: FileWriteHandle, @unchecked Sendable {
        private let file: SFTPFile
        private let lock = NSLock()
        private var position: UInt64
        private var closed = false

        init(file: SFTPFile, position: UInt64) {
            self.file = file
            self.position = position
        }

        func write(_ data: Data) async throws {
            do {
                try await file.write(ByteBuffer(bytes: data), at: position)
                position += UInt64(data.count)
            } catch {
                throw FileSystemSourceError.io(String(describing: error))
            }
        }

        /// May race between writer and the engine's cancellation handler —
        /// first caller wins.
        private func claimClose() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if closed { return false }
            closed = true
            return true
        }

        func close() async throws {
            guard claimClose() else { return }
            try await file.close()
        }
    }

    private static func fileItem(name: String, fullPath: String,
                                 attributes: SFTPFileAttributes, longname: String?) -> FileItem {
        let mode = attributes.permissions
        let typeBits = (mode ?? 0) & 0o170000
        let isDirectory = typeBits == 0o040000
        let isSymlink = typeBits == 0o120000

        // longname is the server's `ls -l` line: "drwxr-xr-x 2 owner group …"
        var owner: String?
        var group: String?
        if let longname {
            let fields = longname.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 4 {
                owner = String(fields[2])
                group = String(fields[3])
            }
        }

        return FileItem(name: name,
                        path: fullPath,
                        isDirectory: isDirectory,
                        isSymlink: isSymlink,
                        isHidden: name.hasPrefix("."),
                        size: isDirectory ? nil : attributes.size.map(Int64.init),
                        modifiedAt: attributes.accessModificationTime?.modificationTime,
                        permissions: mode.map { FilePermissions(rawMode: UInt16($0 & 0o7777)) },
                        owner: owner,
                        group: group)
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private func mapped<T>(path: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw Self.mapError(error, path: path)
        }
    }

    private static func mapError(_ error: Error, path: String) -> Error {
        if error is RemoteSourceError { return error }
        if let sourceError = error as? FileSystemSourceError { return sourceError }
        // Citadel throws the raw Status for request-level failures and wraps
        // it in SFTPError.errorStatus elsewhere — normalize both.
        var status: SFTPMessage.Status?
        if let direct = error as? SFTPMessage.Status {
            status = direct
        } else if case SFTPError.errorStatus(let wrapped) = error {
            status = wrapped
        }
        if let status {
            switch status.errorCode {
            case .noSuchFile:
                return FileSystemSourceError.notFound(path: path)
            case .permissionDenied:
                return FileSystemSourceError.permissionDenied(path: path)
            default:
                return FileSystemSourceError.io(String(describing: status.errorCode))
            }
        }
        return FileSystemSourceError.io(String(describing: error))
    }
}

/// Keep-alive + auto-reconnect hooks (ConnectionSupervisor, M9).
extension SFTPSource: SupervisedConnection {}
