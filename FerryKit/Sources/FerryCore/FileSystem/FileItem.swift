import Foundation

/// POSIX permission bits with display helpers (browser "Perms" column and
/// the chmod editor, M10).
public struct FilePermissions: Hashable, Sendable {
    /// Lower 12 bits of the POSIX mode (rwx for user/group/other + setuid/
    /// setgid/sticky).
    public let rawMode: UInt16

    public init(rawMode: UInt16) {
        self.rawMode = rawMode & 0o7777
    }

    /// e.g. "755" — used by the chmod editor.
    public var octalString: String {
        String(rawMode, radix: 8)
    }

    public init?(octalString: String) {
        guard let mode = UInt16(octalString, radix: 8), mode <= 0o7777 else { return nil }
        self.init(rawMode: mode)
    }

    /// e.g. "rwxr-xr-x" (no leading type character — the browser derives
    /// 'd'/'l' from FileItem flags).
    public var symbolic: String {
        var result = ""
        for shift in [6, 3, 0] {
            let bits = (rawMode >> UInt16(shift)) & 0b111
            result += (bits & 0b100) != 0 ? "r" : "-"
            result += (bits & 0b010) != 0 ? "w" : "-"
            result += (bits & 0b001) != 0 ? "x" : "-"
        }
        return result
    }
}

/// One entry in a directory listing — the unit both panes, the transfer
/// engine, and every backend exchange.
public struct FileItem: Hashable, Sendable, Identifiable {
    /// Absolute path within its source's namespace; unique per source.
    public var id: String { path }

    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isHidden: Bool
    /// nil for directories or when the backend doesn't report a size.
    public let size: Int64?
    public let modifiedAt: Date?
    public let permissions: FilePermissions?
    public let owner: String?
    public let group: String?

    public init(name: String, path: String,
                isDirectory: Bool, isSymlink: Bool = false, isHidden: Bool = false,
                size: Int64? = nil, modifiedAt: Date? = nil,
                permissions: FilePermissions? = nil,
                owner: String? = nil, group: String? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
        self.owner = owner
        self.group = group
    }
}
