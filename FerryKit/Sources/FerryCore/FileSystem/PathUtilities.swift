import Foundation

/// Pure path helpers shared by the browser (sync-browsing mirroring) and,
/// later, the TransferEngine (destination path computation).
public enum PathUtilities {
    /// Relative part of `path` under `anchor`, or nil when `path` is not
    /// inside `anchor`. Same path ⇒ "".
    public static func relativePath(of path: String, under anchor: String) -> String? {
        if path == anchor { return "" }
        let prefix = anchor.hasSuffix("/") ? anchor : anchor + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// Joins without doubling slashes. `join("/a", "b")` = "/a/b",
    /// `join("/", "b")` = "/b".
    public static func join(_ base: String, _ relative: String) -> String {
        guard !relative.isEmpty else { return base }
        return base.hasSuffix("/") ? base + relative : base + "/" + relative
    }
}
