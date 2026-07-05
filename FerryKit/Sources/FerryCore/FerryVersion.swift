import Foundation

/// Central place for the app/kit version until real domain code arrives in M2.
public enum FerryVersion {
    /// Semantic version of FerryKit. Kept in sync with the app's marketing
    /// version (see BUILDING.md → Versioning).
    public static let current = "0.1.0"

    public static var components: (major: Int, minor: Int, patch: Int)? {
        let parts = current.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }
}
