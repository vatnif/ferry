import Foundation
import FerryCore
import OSLog

/// A small diagnostic log honoring Settings ▸ Advanced ▸ Logging (M16). Writes
/// to the unified system log (visible in Console.app) at the configured level;
/// **never** records secrets, key material, or terminal bytes (rule 6). The
/// level is read live from `UserDefaults` on every call, so changing it in
/// Settings takes effect immediately.
///
/// This is intentionally lightweight — a level gate over `os.Logger`, not a
/// logging framework. "Reveal Logs…" points the user at Console filtered to
/// Ferry's subsystem.
enum FerryLog {
    static let subsystem = "com.gfragos.Ferry"
    private static let logger = Logger(subsystem: subsystem, category: "app")

    static var level: LoggingLevel {
        let raw = UserDefaults.standard.string(forKey: AppSettings.Key.loggingLevel)
        return raw.flatMap(LoggingLevel.init(rawValue:)) ?? AppSettings.Default.loggingLevel
    }

    /// An operational error (connect failure, transfer failure). Logged at
    /// `.errors` and `.verbose`.
    static func error(_ message: @autoclosure () -> String) {
        guard level >= .errors else { return }
        let text = message()
        logger.error("\(text, privacy: .public)")
    }

    /// A verbose trace (connect start, disconnect, tab open). Logged only at
    /// `.verbose`.
    static func debug(_ message: @autoclosure () -> String) {
        guard level >= .verbose else { return }
        let text = message()
        logger.debug("\(text, privacy: .public)")
    }
}
