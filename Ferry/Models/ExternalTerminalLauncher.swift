import Foundation
import FerryCore

/// UserDefaults keys backing the terminal-choice setting (M15). The Settings ▸
/// Terminal picker UI arrives with M16 (mockup tab 7); until then these are
/// storage-only — changeable via `defaults write com.gfragos.Ferry …` — with
/// the ADR-023 defaults applied by `TerminalDispatch` (built-in on macOS 15+,
/// Terminal.app on macOS 14 Direct). The raw values are a persistence contract
/// pinned by a unit test.
enum TerminalSettingsKeys {
    static let preference = "terminalPreference"
    static let customCommand = "terminalCustomCommand"
}

/// Reads the stored terminal preference and resolves it against this build's
/// capabilities (macOS version + Direct vs App Store), so both entry points —
/// the browser toolbar toggle and the sidebar "Open Terminal" — dispatch
/// identically (DESIGN.md screen 7, ADR-024).
enum TerminalLaunchService {
    static var storedPreference: TerminalPreference {
        let raw = UserDefaults.standard.string(forKey: TerminalSettingsKeys.preference)
        return raw.flatMap(TerminalPreference.init(rawValue:)) ?? .builtIn
    }

    static var storedCustomCommand: String {
        UserDefaults.standard.string(forKey: TerminalSettingsKeys.customCommand) ?? ""
    }

    /// The resolved decision for a Terminal action in this build/OS.
    static func dispatch() -> TerminalDispatch {
        var builtInAvailable = false
        if #available(macOS 15.0, *) { builtInAvailable = true }
        #if APPSTORE
        let externalAllowed = false
        #else
        let externalAllowed = true
        #endif
        return TerminalDispatch.resolve(preference: storedPreference,
                                        customCommand: storedCustomCommand,
                                        builtInAvailable: builtInAvailable,
                                        externalAllowed: externalAllowed)
    }
}

#if !APPSTORE
import AppKit

/// Hands an ssh command off to an external terminal application (Direct builds
/// only — launching other apps can't work in the App Store sandbox, rule 5 /
/// ADR-024). Passwords are never in the command (rule 6); ssh authenticates and
/// does its own host-key TOFU against `~/.ssh/known_hosts` in the terminal.
///
/// Not headless-testable (it drives Terminal.app/iTerm2 via Apple events and
/// spawns a process) — the injection-safe *string building* it relies on lives
/// in `SSHCommandBuilder` and is unit-tested there (TESTING.md).
enum ExternalTerminalLauncher {
    enum LaunchError: LocalizedError {
        case appleScript(String)
        case processFailed(String)
        var errorDescription: String? {
            switch self {
            case .appleScript(let m): return m
            case .processFailed(let m): return m
            }
        }
    }

    static func launch(_ terminal: ExternalTerminal,
                       command: SSHCommandBuilder.Command) throws {
        switch terminal {
        case .terminalApp:
            try runAppleScript(terminalAppScript(for: command.shellCommand))
        case .iTerm2:
            try runAppleScript(iTermScript(for: command.shellCommand))
        case .custom(let launcher):
            try runCustom(launcher, sshCommand: command.shellCommand)
        }
    }

    // MARK: Terminal.app / iTerm2 via Apple events

    /// `do script` opens a new Terminal window running the command.
    private static func terminalAppScript(for shellCommand: String) -> String {
        let literal = SSHCommandBuilder.appleScriptStringLiteral(shellCommand)
        return """
        tell application "Terminal"
            activate
            do script \(literal)
        end tell
        """
    }

    /// A fresh iTerm window with the default profile, running the command.
    private static func iTermScript(for shellCommand: String) -> String {
        let literal = SSHCommandBuilder.appleScriptStringLiteral(shellCommand)
        return """
        tell application "iTerm"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text \(literal)
            end tell
        end tell
        """
    }

    private static func runAppleScript(_ source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw LaunchError.appleScript("Could not build the terminal launch script.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? "The terminal application could not be launched."
            throw LaunchError.appleScript(message)
        }
    }

    // MARK: Custom command

    /// Runs the user's launcher with the ssh command appended (mockup tab 7:
    /// "receives the ssh command"), through a login shell so PATH resolves
    /// GUI-launched tools (e.g. Homebrew binaries). Detached — Ferry doesn't
    /// wait on the terminal.
    private static func runCustom(_ launcher: String, sshCommand: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "\(launcher) \(sshCommand)"]
        do {
            try process.run()
        } catch {
            throw LaunchError.processFailed(error.localizedDescription)
        }
    }
}
#endif
