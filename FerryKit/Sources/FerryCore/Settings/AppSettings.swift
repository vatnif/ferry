import Foundation

/// The persistence contract + defaults for Ferry's user settings (Settings
/// window, DESIGN.md screen 5, M16). Pure and headless-testable: the typed
/// enums, the `UserDefaults` key strings, and the default values live here so
/// both the app's `@AppStorage` bindings and the models that read settings at
/// runtime agree on one source of truth (and a unit test pins the raw values,
/// which are a storage contract just like `TerminalPreference`).
///
/// This file deliberately holds no `UserDefaults`/AppKit reference — the app
/// layer binds these keys; FerryCore only names them and supplies the pure
/// resolution logic (conflict-name de-duplication, policy → transfer mode).
public enum AppSettings {

    /// `UserDefaults` keys. The two terminal keys keep the exact strings M15
    /// shipped (`ADR-024`, changeable via `defaults write`); the rest are new
    /// in M16. All are a persistence contract — never rename without a
    /// migration (pinned by `AppSettingsTests`).
    public enum Key {
        // Terminal (M15 storage + M16 built-in font/scrollback)
        public static let terminalPreference = "terminalPreference"
        public static let terminalCustomCommand = "terminalCustomCommand"
        public static let terminalFontName = "terminalFontName"
        public static let terminalFontSize = "terminalFontSize"
        public static let terminalScrollbackLines = "terminalScrollbackLines"

        // Transfers
        public static let simultaneousTransfers = "simultaneousTransfers"
        public static let interruptedTransferPolicy = "interruptedTransferPolicy"
        public static let fileExistsPolicy = "fileExistsPolicy"
        public static let retryCount = "transferRetryCount"
        public static let notifyOnQueueFinished = "notifyOnQueueFinished"
        // v1.x — persisted but the controls ship disabled (DESIGN.md screen 5).
        public static let bandwidthLimitEnabled = "bandwidthLimitEnabled"
        public static let verifyChecksums = "verifyChecksums"

        // General
        public static let defaultLocalFolder = "defaultLocalFolder"
        public static let appearance = "appearancePreference"
        public static let reopenLastConnections = "reopenLastConnections"
        /// Session-restore state (not a user-facing setting): the profile IDs
        /// open at last quit. An array so tabs (M16 checkpoint B) can restore
        /// several; today it holds at most one.
        public static let lastOpenConnectionIDs = "lastOpenConnectionIDs"

        // Advanced
        public static let loggingLevel = "loggingLevel"
        public static let experimentalFeatures = "experimentalFeatures"
    }

    /// Shipping defaults (DESIGN.md screen 5 mockup values). Referenced by the
    /// app's `@AppStorage` initial values AND by the models that read settings
    /// without a binding, so a missing key resolves identically everywhere.
    public enum Default {
        public static let terminalFontName = "SF Mono"
        public static let terminalFontSize = 12
        public static let terminalScrollbackLines = 10_000

        public static let simultaneousTransfers = 3
        public static let retryCount = 3
        /// Seconds between retries (DOMAIN.md: 3× / 5 s). Not user-facing in
        /// v1 — the mockup shows "5 s" as fixed copy — but centralized so the
        /// engine and the label agree.
        public static let retryDelaySeconds = 5

        public static let appearance = AppearancePreference.system
        public static let interruptedPolicy = InterruptedTransferPolicy.resume
        public static let existsPolicy = FileExistsPolicy.ask
        public static let loggingLevel = LoggingLevel.errors
    }

    /// Sane bounds for the numeric fields, applied when reading (a stray
    /// `defaults write` or a future migration can't wedge the engine).
    public static let simultaneousTransfersRange = 1...10
    public static let retryCountRange = 0...10
    public static let terminalFontSizeRange = 8...36
    public static let scrollbackLinesRange = 0...1_000_000
}

/// App appearance (General tab). Drives `preferredColorScheme`; `.system`
/// follows macOS.
public enum AppearancePreference: String, CaseIterable, Sendable, Equatable {
    case system, light, dark
}

/// What to do when a transfer is resumed with existing partial data
/// (Transfers tab; DOMAIN.md → Transfers). The default keeps M9's behavior.
public enum InterruptedTransferPolicy: String, CaseIterable, Sendable, Equatable {
    /// Continue from the `.ferrypart` / smaller-remote partial without asking.
    case resume
    /// Ask per interrupted item whether to resume or start over.
    case ask
    /// Always start over at byte 0.
    case restart

    /// The non-interactive transfer mode this policy implies. `.ask` has no
    /// direct mode — the UI resolves it to `.automatic` or `.restart` per the
    /// user's answer — so it maps to `.automatic` as the "no decision yet"
    /// fallback (identical to `.resume`).
    public var transferMode: TransferRequest.Mode {
        switch self {
        case .resume, .ask: return .automatic
        case .restart: return .restart
        }
    }
}

/// What to do when the destination file already exists (Transfers tab;
/// DOMAIN.md conflict policy). The Ask default drives the per-file dialog.
public enum FileExistsPolicy: String, CaseIterable, Sendable, Equatable {
    case overwrite, ask, skip, rename
}

/// Diagnostic logging verbosity (Advanced tab). `Comparable` so a call site
/// can gate on `level >= .verbose`. Secrets/terminal bytes are never logged
/// at any level (rule 6).
public enum LoggingLevel: String, CaseIterable, Sendable, Equatable, Comparable {
    case off, errors, verbose

    private var rank: Int {
        switch self {
        case .off: return 0
        case .errors: return 1
        case .verbose: return 2
        }
    }

    public static func < (lhs: LoggingLevel, rhs: LoggingLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Pure conflict-name de-duplication for the **Rename** exists-policy: given a
/// desired name and the names already present in the destination directory,
/// produce the first non-colliding "`base N.ext`" variant (Finder-style). Kept
/// pure so the collision walk is unit-tested independently of any file system.
public enum TransferNaming {
    /// - Parameters:
    ///   - name: the desired file/folder name (e.g. `report.txt`, `builds`).
    ///   - existing: names already in the destination directory.
    /// - Returns: `name` if free, else `report 2.txt`, `report 3.txt`, … The
    ///   suffix is inserted before the *last* extension only; dotfiles and
    ///   extension-less names get a trailing " N".
    public static func deduplicatedName(for name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let (base, ext) = splitExtension(name)
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }

    /// Splits into (base, extension-without-dot). No extension when the name
    /// is a dotfile (`.bashrc`) or has no dot — matching Finder's rename dedup.
    static func splitExtension(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        let ext = String(name[name.index(after: dot)...])
        // A trailing dot or an empty extension isn't a real extension.
        guard !ext.isEmpty else { return (name, "") }
        return (String(name[..<dot]), ext)
    }
}
