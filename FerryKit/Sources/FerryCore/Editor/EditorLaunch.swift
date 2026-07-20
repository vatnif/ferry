import Foundation

/// A concrete editor to hand a file to, produced by `EditorDispatch` (M19).
/// Never used in App Store builds (launching other apps is Direct-only, rule 5).
public enum EditorTarget: Sendable, Equatable {
    /// Open with the operating system's default application for the file's type
    /// (like double-clicking it in Finder).
    case systemDefault
    /// Open with the application bundle at this file-URL path
    /// (e.g. `/Applications/BBEdit.app`), chosen as the Settings default or via
    /// the per-file "Open With ▸" menu.
    case application(path: String)
}

/// The resolved decision for an "Open in Editor" / "Open With…" action, given
/// the stored default editor, an optional per-file override, and this build's
/// capabilities. Pure and exhaustively unit-tested — the actual app launching
/// (`ExternalEditorLauncher`, app target) is not headless-testable, so this
/// decision layer carries the branching logic (the `TerminalDispatch`
/// precedent, ADR-024).
public enum EditorDispatch: Sendable, Equatable {
    /// Launch an external editor for the file's local (temp) copy.
    case launch(EditorTarget)
    /// Editing isn't possible here — show `reason` to the user.
    case unavailable(reason: String)

    /// The message shown when the round-trip can't run (the sandboxed App Store
    /// build, where launching another app is disallowed).
    public static let appStoreUnavailable =
        "Opening files in an external editor isn’t available in this build."

    /// Resolve which editor opens a remote file's downloaded temp copy.
    ///
    /// - `defaultEditorPath`: the Settings ▸ Editor default — an application
    ///   file-URL path, or empty for "the system default app".
    /// - `override`: a per-file "Open With ▸ <app>" choice (an application
    ///   file-URL path), or nil to use the default.
    /// - `externalAllowed`: the Direct build (`#if !APPSTORE`). Launching other
    ///   apps can't work in the sandboxed App Store build, so it's disallowed
    ///   there.
    public static func resolve(defaultEditorPath: String,
                               override: String?,
                               externalAllowed: Bool) -> EditorDispatch {
        guard externalAllowed else {
            return .unavailable(reason: appStoreUnavailable)
        }
        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return .launch(.application(path: trimmed)) }
        }
        let def = defaultEditorPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return .launch(def.isEmpty ? .systemDefault : .application(path: def))
    }
}
