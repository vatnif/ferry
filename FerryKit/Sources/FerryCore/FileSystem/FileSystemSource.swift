import Foundation

/// Sequential sink returned by `openWrite`. The TransferEngine writes chunks
/// in order and closes exactly once; implementations may assume no
/// concurrent calls on one handle.
public protocol FileWriteHandle: Sendable {
    func write(_ data: Data) async throws
    /// Must be called to finalize; safe to call after a failure.
    func close() async throws
}

/// THE core abstraction (ARCHITECTURE.md): both panes, the TransferEngine,
/// and all backends (local, SFTP, FTP, SCP, later WebDAV/S3) meet here.
/// Paths are absolute strings in the source's own namespace.
///
/// Offset semantics (the resume seam, DOMAIN.md → Transfers):
/// - `openRead(at:offset:)` starts streaming at byte `offset`.
/// - `openWrite(at:offset:)` truncates the target to `offset` bytes, then
///   appends — offset 0 is a plain overwrite; offset == current size resumes.
public protocol FileSystemSource: Sendable {
    /// Shown in the pane header (e.g. "This Mac", "prod-web-01").
    var displayName: String { get }

    /// Start directory when a pane opens without a configured path.
    func homeDirectory() async throws -> String

    /// Non-recursive listing. `includeHidden: false` filters dotfiles and
    /// platform-hidden entries.
    func list(directory path: String, includeHidden: Bool) async throws -> [FileItem]

    func stat(path: String) async throws -> FileItem

    /// Creates intermediate directories as needed.
    func createDirectory(at path: String) async throws

    /// Files and directories; directories recursively (UI confirms first,
    /// DOMAIN.md).
    func delete(at path: String) async throws

    /// Rename or move within the same source (full destination path).
    func rename(from sourcePath: String, to destinationPath: String) async throws

    func setPermissions(_ permissions: FilePermissions, at path: String) async throws

    func openRead(at path: String, offset: Int64) async throws -> AsyncThrowingStream<Data, Error>

    func openWrite(at path: String, offset: Int64) async throws -> any FileWriteHandle
}

public enum FileSystemSourceError: Error, Equatable {
    case notFound(path: String)
    case notADirectory(path: String)
    case alreadyExists(path: String)
    case permissionDenied(path: String)
    case invalidOffset(Int64)
    case io(String)
}
