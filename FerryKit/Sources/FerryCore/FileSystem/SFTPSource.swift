@preconcurrency import Citadel
import Foundation
import NIOCore

/// Errors surfaced while establishing a remote session (before the
/// FileSystemSource contract applies).
public enum RemoteSourceError: Error, Equatable {
    case authenticationFailed
    case connectionFailed(String)
}

/// FileSystemSource over SFTP via Citadel (ADR-011). M6 scope is read-only:
/// browse + download. Mutations and uploads land with the TransferEngine and
/// file-operations milestones (M8/M10); until then they throw `.unsupported`.
///
/// Host keys are currently accepted blindly — M11 replaces the validator
/// with the TOFU flow (HostKeyStore + prompt, DOMAIN.md → Host key trust).
public actor SFTPSource: FileSystemSource {
    public nonisolated let displayName: String
    private let ssh: SSHClient
    private let sftp: SFTPClient

    static let readChunkLength: UInt32 = 128 * 1024

    private init(displayName: String, ssh: SSHClient, sftp: SFTPClient) {
        self.displayName = displayName
        self.ssh = ssh
        self.sftp = sftp
    }

    /// Password-authenticated connect (key/agent auth arrives in M11).
    public static func connect(host: String,
                               port: Int = 22,
                               username: String,
                               password: String,
                               displayName: String? = nil) async throws -> SFTPSource {
        let ssh: SSHClient
        do {
            ssh = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: .passwordBased(username: username, password: password),
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
            let sftp = try await ssh.openSFTP()
            return SFTPSource(displayName: displayName ?? host, ssh: ssh, sftp: sftp)
        } catch {
            try? await ssh.close()
            throw RemoteSourceError.connectionFailed(String(describing: error))
        }
    }

    public func disconnect() async {
        try? await sftp.close()
        try? await ssh.close()
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

        return AsyncThrowingStream(Data.self, bufferingPolicy: .bufferingNewest(4)) { continuation in
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

    // MARK: Mutations — deferred milestones

    public func createDirectory(at path: String) async throws {
        throw FileSystemSourceError.unsupported(operation: "SFTP createDirectory (M10)")
    }

    public func delete(at path: String) async throws {
        throw FileSystemSourceError.unsupported(operation: "SFTP delete (M10)")
    }

    public func rename(from sourcePath: String, to destinationPath: String) async throws {
        throw FileSystemSourceError.unsupported(operation: "SFTP rename (M10)")
    }

    public func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        throw FileSystemSourceError.unsupported(operation: "SFTP setPermissions (M10)")
    }

    public func openWrite(at path: String, offset: Int64) async throws -> any FileWriteHandle {
        throw FileSystemSourceError.unsupported(operation: "SFTP upload (M8)")
    }

    // MARK: Internals

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
