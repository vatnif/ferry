import Foundation

/// Persists security-scoped bookmarks for user-granted folders — the App
/// Store build's key to the local filesystem (DOMAIN.md → Sandbox strategy).
/// In unsandboxed Direct builds the same code runs and simply isn't needed
/// for access, keeping one code path for both distributions.
///
/// Storage: JSON dictionary path → base64 bookmark data, next to
/// connections.json (no secrets — bookmarks only grant what the user already
/// granted via the open panel).
public final class SecurityScopedBookmarkStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var bookmarks: [String: Data]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Data].self, from: data) {
            bookmarks = decoded
        } else {
            bookmarks = [:]
        }
    }

    /// Registers a folder the user granted via NSOpenPanel/fileImporter.
    public func addGrantedFolder(_ url: URL) throws {
        let data = try url.bookmarkData(options: .withSecurityScope,
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        lock.lock()
        bookmarks[url.path] = data
        let snapshot = bookmarks
        lock.unlock()
        try persist(snapshot)
    }

    public func removeGrantedFolder(path: String) throws {
        lock.lock()
        bookmarks.removeValue(forKey: path)
        let snapshot = bookmarks
        lock.unlock()
        try persist(snapshot)
    }

    /// Paths of all granted folders (feeds a future "grant access…" UI).
    public var grantedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return bookmarks.keys.sorted()
    }

    /// Runs `body` with security-scoped access started for the granted folder
    /// containing `path` (deepest match). No matching grant ⇒ runs without —
    /// correct for the Direct build and for container-internal paths.
    public func withAccess<T>(toPathContaining path: String, _ body: () throws -> T) rethrows -> T {
        guard let url = resolveGrant(forPathContaining: path) else {
            return try body()
        }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private func resolveGrant(forPathContaining path: String) -> URL? {
        lock.lock()
        let candidates = bookmarks.filter { path == $0.key || path.hasPrefix($0.key + "/") }
        lock.unlock()
        guard let best = candidates.max(by: { $0.key.count < $1.key.count }) else { return nil }

        var stale = false
        guard let url = try? URL(resolvingBookmarkData: best.value,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale {
            // Refresh the bookmark for next time; access still works now.
            try? addGrantedFolder(url)
        }
        return url
    }

    private func persist(_ snapshot: [String: Data]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
