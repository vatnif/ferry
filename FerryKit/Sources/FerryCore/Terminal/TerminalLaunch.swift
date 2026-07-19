import Foundation

/// Which terminal the "Terminal" action opens (DOMAIN.md → Terminal hand-off,
/// M15 / ADR-024). Stored as a raw string in `UserDefaults` (@AppStorage-friendly);
/// the associated custom command is stored separately (see `TerminalDispatch`).
///
/// The default is always `.builtIn`: the *dispatch resolver* — not a
/// version-dependent stored default — maps built-in + macOS 14 + Direct to the
/// Terminal.app fallback (ADR-023 defaults), so one static default yields the
/// right behavior on every configuration.
public enum TerminalPreference: String, CaseIterable, Sendable, Equatable {
    /// Ferry's embedded terminal (M15.5). Requires macOS 15.
    case builtIn
    /// Apple Terminal.app (external hand-off, Direct builds only).
    case terminalApp
    /// iTerm2 (external hand-off, Direct builds only).
    case iTerm2
    /// A user-supplied command that receives the built ssh command (Direct only).
    case custom
}

/// A concrete external terminal to hand off to, produced by `TerminalDispatch`.
/// Never appears in App Store builds (launching other apps is Direct-only).
public enum ExternalTerminal: Sendable, Equatable {
    case terminalApp
    case iTerm2
    /// The command line the user configured; the ssh command is appended to it.
    case custom(command: String)

    /// Human-readable name for error messages ("Could not open …").
    public var displayName: String {
        switch self {
        case .terminalApp: return "Terminal"
        case .iTerm2: return "iTerm"
        case .custom: return "the custom terminal command"
        }
    }
}

/// The resolved decision for a Terminal action, given the stored preference and
/// the runtime environment. Pure and exhaustively unit-tested — the actual
/// app-launching (`ExternalTerminalLauncher`, app target) is not headless-testable
/// (TESTING.md), so this decision layer carries the branching logic.
public enum TerminalDispatch: Sendable, Equatable {
    /// Open Ferry's embedded terminal (panel or window).
    case builtIn
    /// Hand off to an external terminal app (Direct builds).
    case external(ExternalTerminal)
    /// Neither is possible here — show `reason` to the user.
    case unavailable(reason: String)

    /// Resolve the Terminal action.
    ///
    /// - `preference`/`customCommand`: the stored user choice.
    /// - `builtInAvailable`: macOS 15+ (Citadel's `withPTY` gate, ADR-023).
    /// - `externalAllowed`: the Direct build (`#if !APPSTORE`) — launching other
    ///   apps is disallowed in the sandboxed App Store build.
    ///
    /// Fallbacks (ADR-023): built-in on macOS 14 Direct falls back to Terminal.app;
    /// an external preference that can't run (App Store) degrades to the built-in
    /// terminal when available, otherwise reports the macOS-15 explainer.
    public static func resolve(preference: TerminalPreference,
                               customCommand: String,
                               builtInAvailable: Bool,
                               externalAllowed: Bool) -> TerminalDispatch {
        let macOS15Explainer = "The built-in terminal requires macOS 15 or later."

        func builtInOrExplain() -> TerminalDispatch {
            builtInAvailable ? .builtIn : .unavailable(reason: macOS15Explainer)
        }

        switch preference {
        case .builtIn:
            if builtInAvailable { return .builtIn }
            // macOS 14: fall back to Terminal.app in the Direct build; the App
            // Store build has no external option, so explain the gate.
            return externalAllowed ? .external(.terminalApp)
                                   : .unavailable(reason: macOS15Explainer)

        case .terminalApp:
            return externalAllowed ? .external(.terminalApp) : builtInOrExplain()

        case .iTerm2:
            return externalAllowed ? .external(.iTerm2) : builtInOrExplain()

        case .custom:
            guard externalAllowed else { return builtInOrExplain() }
            let trimmed = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .unavailable(reason: "No custom terminal command is set. Choose a terminal in Settings ▸ Terminal.")
            }
            return .external(.custom(command: trimmed))
        }
    }
}

/// Builds the `ssh` command Ferry hands to an external terminal (M15, ADR-024).
///
/// Pure and injection-safe: the profile's host/user/key-path/start-path are
/// treated as untrusted and shell-quoted (the SCPSource precedent, ADR-020).
/// **Passwords are never included** — the built command carries key auth (`-i`)
/// at most; a password profile relies on ssh prompting in the terminal (rule 6).
/// ssh performs its own host-key TOFU against the user's `~/.ssh/known_hosts`,
/// independent of Ferry's store (DOMAIN.md).
public struct SSHCommandBuilder {

    /// A built ssh invocation in two equivalent forms.
    public struct Command: Sendable, Equatable {
        /// Raw argv, each element literal at the *local* shell level (the
        /// remote-command element carries its own remote-shell quoting).
        public let arguments: [String]

        /// A single, locally-shell-safe command line (for AppleScript `do
        /// script` and for appending to a custom command). Each argument is
        /// quoted only when it contains characters outside a safe set.
        public var shellCommand: String {
            arguments.map(SSHCommandBuilder.shellQuote).joined(separator: " ")
        }
    }

    /// Build the ssh command for a profile.
    ///
    /// - `keyPath`: the private-key path for `.publicKey` auth, else nil. A
    ///   leading `~` is expanded via `homeDirectory` so a quoted path still
    ///   resolves (tilde only expands unquoted, and a path with spaces must be
    ///   quoted).
    /// - `remoteStartPath`: when set, forces a PTY (`-t`) and runs
    ///   `cd '<path>'; exec $SHELL -l` so the shell opens in that directory
    ///   (falling through to the home shell if the `cd` fails).
    public static func build(host: String,
                             port: Int,
                             username: String,
                             keyPath: String?,
                             remoteStartPath: String?,
                             homeDirectory: String = NSHomeDirectory()) -> Command {
        var args = ["ssh"]

        // Only emit -p for a non-default port, matching what a user would type.
        if port != 22 {
            args.append("-p")
            args.append(String(port))
        }

        if let key = keyPath?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            args.append("-i")
            args.append(expandTilde(key, home: homeDirectory))
        }

        let start = remoteStartPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start, !start.isEmpty {
            // Force PTY allocation so the remote-command form still yields an
            // interactive login shell.
            args.append("-t")
        }

        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        args.append(user.isEmpty ? host : "\(user)@\(host)")

        if let start, !start.isEmpty {
            // The path is quoted for the *remote* shell here; the whole element
            // is then quoted again for the local shell by `shellCommand`.
            args.append("cd \(shellQuote(start)); exec $SHELL -l")
        }

        return Command(arguments: args)
    }

    /// Expand a leading `~` / `~/` against `home`. Non-tilde paths pass through.
    static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home + path.dropFirst(1)   // keep the leading "/"
        }
        return path
    }

    /// POSIX-shell-quote an argument, quoting only when it contains anything
    /// outside a conservative safe set (the shlex.quote approach): keeps common
    /// commands readable while single-quoting anything that could inject.
    /// Embedded single quotes become the `'\''` idiom (the SCPSource precedent).
    public static func shellQuote(_ argument: String) -> String {
        if argument.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%+=:,./-_")
        if argument.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape a string for embedding inside an AppleScript double-quoted string
    /// literal (`do script "…"`). Pure so the injection surface stays tested;
    /// the launcher (app target) uses it. Backslash first, then quote.
    public static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
