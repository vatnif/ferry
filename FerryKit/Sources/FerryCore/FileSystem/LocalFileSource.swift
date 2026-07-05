import Foundation

/// FileSystemSource over the local disk (FileManager/FileHandle). The local
/// pane is "just another source" (ARCHITECTURE.md), which keeps the dual-pane
/// UI symmetric and enables remote↔remote later.
///
/// Sandbox strategy (DOMAIN.md): every operation is wrapped in
/// `bookmarks.withAccess(toPathContaining:)` — a no-op for paths that are
/// freely accessible (always the case in unsandboxed Direct builds), and a
/// security-scoped start/stop for bookmarked folders in the App Store build.
public struct LocalFileSource: FileSystemSource {
    public let displayName = "This Mac"
    private let bookmarks: SecurityScopedBookmarkStore?

    public init(bookmarks: SecurityScopedBookmarkStore? = nil) {
        self.bookmarks = bookmarks
    }

    public func homeDirectory() async throws -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    public func list(directory path: String, includeHidden: Bool) async throws -> [FileItem] {
        try withAccess(path) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                throw FileSystemSourceError.notFound(path: path)
            }
            guard isDir.boolValue else {
                throw FileSystemSourceError.notADirectory(path: path)
            }
            let contents: [URL]
            do {
                contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Array(Self.resourceKeys),
                    options: [])
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                throw FileSystemSourceError.permissionDenied(path: path)
            }
            return try contents.compactMap { itemURL in
                let item = try Self.fileItem(at: itemURL)
                return (includeHidden || !item.isHidden) ? item : nil
            }
        }
    }

    public func stat(path: String) async throws -> FileItem {
        try withAccess(path) {
            guard FileManager.default.fileExists(atPath: path) else {
                throw FileSystemSourceError.notFound(path: path)
            }
            return try Self.fileItem(at: URL(fileURLWithPath: path))
        }
    }

    public func createDirectory(at path: String) async throws {
        try withAccess(path) {
            if FileManager.default.fileExists(atPath: path) {
                throw FileSystemSourceError.alreadyExists(path: path)
            }
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    public func delete(at path: String) async throws {
        try withAccess(path) {
            guard FileManager.default.fileExists(atPath: path) else {
                throw FileSystemSourceError.notFound(path: path)
            }
            try FileManager.default.removeItem(atPath: path)
        }
    }

    public func rename(from sourcePath: String, to destinationPath: String) async throws {
        try withAccess(sourcePath) {
            guard FileManager.default.fileExists(atPath: sourcePath) else {
                throw FileSystemSourceError.notFound(path: sourcePath)
            }
            if FileManager.default.fileExists(atPath: destinationPath) {
                throw FileSystemSourceError.alreadyExists(path: destinationPath)
            }
            try FileManager.default.moveItem(atPath: sourcePath, toPath: destinationPath)
        }
    }

    public func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        try withAccess(path) {
            guard FileManager.default.fileExists(atPath: path) else {
                throw FileSystemSourceError.notFound(path: path)
            }
            try FileManager.default.setAttributes([.posixPermissions: Int(permissions.rawMode)],
                                                  ofItemAtPath: path)
        }
    }

    public func openRead(at path: String, offset: Int64) async throws -> AsyncThrowingStream<Data, Error> {
        guard offset >= 0 else { throw FileSystemSourceError.invalidOffset(offset) }
        let handle: FileHandle
        do {
            handle = try withAccess(path) { try FileHandle(forReadingFrom: URL(fileURLWithPath: path)) }
        } catch let error as FileSystemSourceError {
            throw error
        } catch {
            throw FileSystemSourceError.notFound(path: path)
        }
        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            try? handle.close()
            throw FileSystemSourceError.invalidOffset(offset)
        }

        // Unbounded buffering: dropping chunks (bufferingNewest) would corrupt
        // transfers. Memory is bounded in practice by the reader thread pacing
        // below; proper backpressure is an M9 concern.
        let chunkSize = Self.readChunkSize
        return AsyncThrowingStream(Data.self) { continuation in
            let reader = Thread {
                do {
                    while true {
                        guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: FileSystemSourceError.io(error.localizedDescription))
                }
                try? handle.close()
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { try? handle.close() }
            }
            reader.start()
        }
    }

    public func openWrite(at path: String, offset: Int64) async throws -> any FileWriteHandle {
        guard offset >= 0 else { throw FileSystemSourceError.invalidOffset(offset) }
        return try withAccess(path) {
            if !FileManager.default.fileExists(atPath: path) {
                // Resuming (offset > 0) into a missing file: notFound, matching
                // SFTPSource — the caller falls back to a fresh transfer.
                guard offset == 0 else { throw FileSystemSourceError.notFound(path: path) }
                guard FileManager.default.createFile(atPath: path, contents: nil) else {
                    throw FileSystemSourceError.permissionDenied(path: path)
                }
            }
            let handle: FileHandle
            do {
                handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            } catch {
                throw FileSystemSourceError.permissionDenied(path: path)
            }
            do {
                // Contract: truncate to `offset`, then append (resume seam).
                try handle.truncate(atOffset: UInt64(offset))
                try handle.seekToEnd()
            } catch {
                try? handle.close()
                throw FileSystemSourceError.invalidOffset(offset)
            }
            return LocalFileWriteHandle(handle: handle)
        }
    }

    // MARK: - Internals

    static let readChunkSize = 256 * 1024

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey,
    ]

    private static func fileItem(at url: URL) throws -> FileItem {
        let values = try url.resourceValues(forKeys: resourceKeys)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes?[.posixPermissions] as? NSNumber).map { FilePermissions(rawMode: $0.uint16Value) }
        let isDirectory = values.isDirectory ?? false
        return FileItem(name: url.lastPathComponent,
                        path: url.path,
                        isDirectory: isDirectory,
                        isSymlink: values.isSymbolicLink ?? false,
                        isHidden: (values.isHidden ?? false) || url.lastPathComponent.hasPrefix("."),
                        size: isDirectory ? nil : (values.fileSize).map(Int64.init),
                        modifiedAt: values.contentModificationDate,
                        permissions: mode,
                        owner: attributes?[.ownerAccountName] as? String,
                        group: attributes?[.groupOwnerAccountName] as? String)
    }

    private func withAccess<T>(_ path: String, _ body: () throws -> T) throws -> T {
        guard let bookmarks else { return try body() }
        return try bookmarks.withAccess(toPathContaining: path, body)
    }
}

/// Sequential writer over FileHandle. @unchecked Sendable: the
/// FileWriteHandle contract guarantees no concurrent use of one handle.
final class LocalFileWriteHandle: FileWriteHandle, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) async throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw FileSystemSourceError.io(error.localizedDescription)
        }
    }

    /// close() may race between the writer and the engine's cancellation
    /// handler — first caller wins, the rest are no-ops.
    private func claimClose() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if closed { return false }
        closed = true
        return true
    }

    func close() async throws {
        guard claimClose() else { return }
        try handle.close()
    }

    deinit {
        if claimClose() { try? handle.close() }
    }
}
