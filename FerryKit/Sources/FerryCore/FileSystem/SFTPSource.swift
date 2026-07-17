@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOSSH

/// How an SSH session authenticates. A Sendable value the app builds and hands
/// to `SFTPSource.connect`: the app owns file access (sandbox / security-scoped
/// bookmarks) and reads the key bytes; FerryCore owns parsing (SSHKeyLoader).
/// Key material is held in memory only — never logged or persisted (DOMAIN.md).
public enum SSHAuthCredential: Sendable {
    case password(String)
    case privateKey(pem: Data, passphrase: String?)
}

/// Errors surfaced while establishing a remote session (before the
/// FileSystemSource contract applies).
public enum RemoteSourceError: Error, Equatable {
    case authenticationFailed
    case connectionFailed(String)
    /// First contact: the server offered a host key Ferry has never seen for
    /// this endpoint. The app shows the TOFU prompt (screen 3), and on approval
    /// trusts the key and retries — DOMAIN.md → Host key trust.
    case hostKeyUnknown(HostKeyInfo)
    /// The server offered a host key that differs from every key Ferry already
    /// trusts for this endpoint — a possible MITM. The app shows the changed-key
    /// alarm; there is no silent-accept path.
    case hostKeyChanged(stored: [HostKeyInfo], offered: HostKeyInfo)
}

/// FileSystemSource over SFTP via Citadel (ADR-011). Read side since M6,
/// writes since M8, mkdir + reconnect support since M9, rename + chmod
/// since M10 — the full mutation surface is now live.
///
/// Host keys are verified TOFU since M11: `connect` validates against the
/// HostKeyStore and throws `hostKeyUnknown`/`hostKeyChanged` for the app to
/// resolve (DOMAIN.md → Host key trust). Password + SSH-key auth (ed25519/RSA).
public actor SFTPSource: FileSystemSource {
    /// Everything needed to rebuild the transport for auto-reconnect (M9).
    /// Held in memory only — never logged or persisted (DOMAIN.md). Includes
    /// the credential (incl. key material) and the trust store, so a silent
    /// reconnect re-validates the host key exactly as the first connect did.
    private struct Parameters {
        var host: String
        var port: Int
        var username: String
        var credential: SSHAuthCredential
        var hostKeyStore: HostKeyStore
        /// A key trusted for this session only (the user declined "remember").
        /// Merged into the validator's trusted set and kept so a mid-session
        /// reconnect still succeeds, but never written to the store.
        var sessionTrusted: HostKeyInfo?
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

    /// Establishes an SFTP session with TOFU host-key verification.
    ///
    /// Throws `RemoteSourceError.hostKeyUnknown`/`.hostKeyChanged` when the
    /// offered host key isn't trusted (the app resolves trust and retries),
    /// `.authenticationFailed` on bad credentials, `SSHKeyLoadError` when a key
    /// file can't be parsed (e.g. a passphrase is needed), and
    /// `.connectionFailed` otherwise.
    /// - Parameter sessionTrusted: a host key to trust for this session only
    ///   (the user declined "remember this key"); not persisted, but honored on
    ///   an in-session reconnect.
    public static func connect(host: String,
                               port: Int = 22,
                               username: String,
                               credential: SSHAuthCredential,
                               hostKeyStore: HostKeyStore,
                               sessionTrusted: HostKeyInfo? = nil,
                               displayName: String? = nil) async throws -> SFTPSource {
        let parameters = Parameters(host: host, port: port, username: username,
                                    credential: credential, hostKeyStore: hostKeyStore,
                                    sessionTrusted: sessionTrusted)
        let (ssh, sftp) = try await establish(parameters)
        return SFTPSource(displayName: displayName ?? host, ssh: ssh, sftp: sftp,
                          parameters: parameters)
    }

    private static func establish(_ parameters: Parameters) async throws -> (SSHClient, SFTPClient) {
        var trusted = (try? parameters.hostKeyStore.trustedKeys(host: parameters.host,
                                                                port: parameters.port)) ?? []
        if let sessionTrusted = parameters.sessionTrusted,
           let key = try? NIOSSHPublicKey(openSSHPublicKey: sessionTrusted.openSSH) {
            trusted.insert(key)
        }
        let validator = TOFUHostKeyValidator(trusted: trusted)
        // Key parsing errors (incl. passphraseRequired) propagate untouched so
        // the app can prompt — they must not be swallowed as connection errors.
        let authMethod = try makeAuthMethod(parameters)

        let ssh: SSHClient
        do {
            ssh = try await SSHClient.connect(
                host: parameters.host,
                port: parameters.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .custom(validator),
                reconnect: .never)
        } catch {
            // A rejected, untrusted host key is the reason for the failure —
            // classify it as unknown (first contact) vs. changed (MITM risk).
            if validator.rejectedUntrustedKey, let offered = validator.offeredKey {
                let offeredInfo = HostKeyInfo(publicKey: offered)
                let stored = (try? parameters.hostKeyStore.storedInfos(host: parameters.host,
                                                                       port: parameters.port)) ?? []
                throw stored.isEmpty
                    ? RemoteSourceError.hostKeyUnknown(offeredInfo)
                    : RemoteSourceError.hostKeyChanged(stored: stored, offered: offeredInfo)
            }
            throw Self.mapConnectError(error)
        }

        do {
            return (ssh, try await ssh.openSFTP())
        } catch {
            try? await ssh.close()
            throw RemoteSourceError.connectionFailed(String(describing: error))
        }
    }

    private static func makeAuthMethod(_ parameters: Parameters) throws -> SSHAuthenticationMethod {
        switch parameters.credential {
        case .password(let password):
            return .passwordBased(username: parameters.username, password: password)
        case .privateKey(let pem, let passphrase):
            return try SSHKeyLoader.authenticationMethod(username: parameters.username,
                                                         pem: pem, passphrase: passphrase)
        }
    }

    private static func mapConnectError(_ error: Error) -> RemoteSourceError {
        if error is Citadel.AuthenticationFailed { return .authenticationFailed }
        if case SSHClientError.allAuthenticationOptionsFailed = error { return .authenticationFailed }
        return .connectionFailed(String(describing: error))
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
