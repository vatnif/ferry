import XCTest
@testable import FerryCore

/// Unit tests for the Terminal hand-off logic (M15, ADR-024): the pure
/// ssh-command builder (quoting/injection, port/user/key/start-path
/// permutations, never a password) and the dispatch decision matrix
/// (built-in vs external vs unavailable across macOS 14/15 × Direct/App Store).
/// The actual app-launching is not headless-testable (TESTING.md).
final class TerminalLaunchTests: XCTestCase {

    // MARK: ssh-command builder — happy paths

    func testMinimalCommandDefaultPortNoKey() {
        let cmd = SSHCommandBuilder.build(host: "example.com", port: 22,
                                          username: "alice", keyPath: nil,
                                          remoteStartPath: nil)
        XCTAssertEqual(cmd.arguments, ["ssh", "alice@example.com"])
        XCTAssertEqual(cmd.shellCommand, "ssh alice@example.com")
    }

    func testNonDefaultPortEmitsDashP() {
        let cmd = SSHCommandBuilder.build(host: "host", port: 2223,
                                          username: "ferry", keyPath: nil,
                                          remoteStartPath: nil)
        XCTAssertEqual(cmd.arguments, ["ssh", "-p", "2223", "ferry@host"])
        XCTAssertEqual(cmd.shellCommand, "ssh -p 2223 ferry@host")
    }

    func testKeyPathEmitsDashI() {
        let cmd = SSHCommandBuilder.build(host: "host", port: 22,
                                          username: "ferry",
                                          keyPath: "/keys/id_ed25519",
                                          remoteStartPath: nil)
        XCTAssertEqual(cmd.arguments, ["ssh", "-i", "/keys/id_ed25519", "ferry@host"])
    }

    func testTildeInKeyPathExpandsAgainstInjectedHome() {
        let cmd = SSHCommandBuilder.build(host: "host", port: 22,
                                          username: "ferry",
                                          keyPath: "~/.ssh/id_ed25519",
                                          remoteStartPath: nil,
                                          homeDirectory: "/Users/ferry")
        XCTAssertEqual(cmd.arguments,
                       ["ssh", "-i", "/Users/ferry/.ssh/id_ed25519", "ferry@host"])
    }

    func testBareTildeExpandsToHome() {
        XCTAssertEqual(SSHCommandBuilder.expandTilde("~", home: "/Users/ferry"), "/Users/ferry")
        XCTAssertEqual(SSHCommandBuilder.expandTilde("~/x", home: "/Users/ferry"), "/Users/ferry/x")
        // A tilde that isn't a home reference passes through untouched.
        XCTAssertEqual(SSHCommandBuilder.expandTilde("/a/~b", home: "/Users/ferry"), "/a/~b")
    }

    func testRemoteStartPathForcesPTYAndCdExec() {
        let cmd = SSHCommandBuilder.build(host: "host", port: 22,
                                          username: "ferry", keyPath: nil,
                                          remoteStartPath: "/var/www")
        // A safe path needs no inner quoting; the whole remote-command element
        // is still quoted once for the local shell in shellCommand.
        XCTAssertEqual(cmd.arguments,
                       ["ssh", "-t", "ferry@host", "cd /var/www; exec $SHELL -l"])
        XCTAssertEqual(cmd.shellCommand,
                       "ssh -t ferry@host 'cd /var/www; exec $SHELL -l'")
    }

    func testAllOptionsTogether() {
        let cmd = SSHCommandBuilder.build(host: "host", port: 2200,
                                          username: "ferry",
                                          keyPath: "/k/id",
                                          remoteStartPath: "/srv")
        XCTAssertEqual(cmd.arguments,
                       ["ssh", "-p", "2200", "-i", "/k/id", "-t", "ferry@host",
                        "cd /srv; exec $SHELL -l"])
    }

    func testEmptyUsernameOmitsAtPrefix() {
        let cmd = SSHCommandBuilder.build(host: "host", port: 22,
                                          username: "", keyPath: nil,
                                          remoteStartPath: nil)
        XCTAssertEqual(cmd.arguments, ["ssh", "host"])
    }

    func testWhitespaceOnlyStartPathIgnored() {
        let cmd = SSHCommandBuilder.build(host: "host", port: 22,
                                          username: "ferry", keyPath: "  ",
                                          remoteStartPath: "   ")
        // Blank key and blank start path are both dropped.
        XCTAssertEqual(cmd.arguments, ["ssh", "ferry@host"])
    }

    // MARK: ssh-command builder — never a password

    /// The builder takes no password parameter at all; prove no auth secret can
    /// reach the command regardless of the profile's inputs.
    func testNoPasswordEverAppearsInCommand() {
        let secret = "hunter2SECRET"
        // A password profile carries no keyPath; feed the secret into every
        // string field the builder does accept and assert it never surfaces.
        let cmd = SSHCommandBuilder.build(host: "host-\(secret)", port: 22,
                                          username: "user-\(secret)",
                                          keyPath: nil,
                                          remoteStartPath: "/path-\(secret)")
        // The secret appears only because we deliberately embedded it in the
        // host/user/path — but there is no "-p <password>" / password token: the
        // only "-p" that could appear is the *port* flag, absent here.
        XCTAssertFalse(cmd.arguments.contains("-p"))
        XCTAssertFalse(cmd.shellCommand.contains("password"))
        XCTAssertFalse(cmd.shellCommand.contains("sshpass"))
    }

    // MARK: ssh-command builder — injection / quoting

    func testHostWithShellMetacharactersIsQuoted() {
        let cmd = SSHCommandBuilder.build(host: "h; rm -rf /", port: 22,
                                          username: "ferry", keyPath: nil,
                                          remoteStartPath: nil)
        // The argv keeps the literal (ssh sees it as one arg); the shell command
        // single-quotes it so the local shell can't interpret ; or spaces.
        XCTAssertEqual(cmd.arguments, ["ssh", "ferry@h; rm -rf /"])
        XCTAssertEqual(cmd.shellCommand, "ssh 'ferry@h; rm -rf /'")
    }

    func testStartPathWithEmbeddedSingleQuoteIsEscaped() {
        let cmd = SSHCommandBuilder.build(host: "host", port: 22,
                                          username: "ferry", keyPath: nil,
                                          remoteStartPath: "/a'b")
        XCTAssertEqual(cmd.arguments.last, "cd '/a'\\''b'; exec $SHELL -l")
    }

    func testKeyPathWithSpacesIsQuotedInShellCommand() {
        let cmd = SSHCommandBuilder.build(host: "host", port: 22,
                                          username: "ferry",
                                          keyPath: "/my keys/id",
                                          remoteStartPath: nil)
        XCTAssertEqual(cmd.arguments, ["ssh", "-i", "/my keys/id", "ferry@host"])
        XCTAssertEqual(cmd.shellCommand, "ssh -i '/my keys/id' ferry@host")
    }

    func testShellQuoteSafeAndUnsafe() {
        XCTAssertEqual(SSHCommandBuilder.shellQuote("plain@host.com:22"), "plain@host.com:22")
        XCTAssertEqual(SSHCommandBuilder.shellQuote("has space"), "'has space'")
        XCTAssertEqual(SSHCommandBuilder.shellQuote(""), "''")
        XCTAssertEqual(SSHCommandBuilder.shellQuote("a'b"), "'a'\\''b'")
        XCTAssertEqual(SSHCommandBuilder.shellQuote("$(whoami)"), "'$(whoami)'")
        XCTAssertEqual(SSHCommandBuilder.shellQuote("a`b`"), "'a`b`'")
    }

    // MARK: AppleScript string-literal escaping

    func testAppleScriptEscaping() {
        XCTAssertEqual(SSHCommandBuilder.appleScriptStringLiteral("ssh host"),
                       "\"ssh host\"")
        // A double quote and a backslash both get escaped for the AS literal.
        XCTAssertEqual(SSHCommandBuilder.appleScriptStringLiteral("say \"hi\""),
                       "\"say \\\"hi\\\"\"")
        XCTAssertEqual(SSHCommandBuilder.appleScriptStringLiteral("a\\b"),
                       "\"a\\\\b\"")
    }

    func testAppleScriptEscapingOfAQuotedShellCommand() {
        // End-to-end: a start-path shell command (single quotes + $) embedded in
        // an AppleScript literal must escape nothing but is proven stable.
        let cmd = SSHCommandBuilder.build(host: "host", port: 22,
                                          username: "ferry", keyPath: nil,
                                          remoteStartPath: "/srv")
        let literal = SSHCommandBuilder.appleScriptStringLiteral(cmd.shellCommand)
        XCTAssertEqual(literal,
                       "\"ssh -t ferry@host 'cd /srv; exec $SHELL -l'\"")
    }

    // MARK: dispatch decision matrix

    func testBuiltInPreferenceOnMacOS15() {
        XCTAssertEqual(
            TerminalDispatch.resolve(preference: .builtIn, customCommand: "",
                                     builtInAvailable: true, externalAllowed: true),
            .builtIn)
    }

    func testBuiltInPreferenceMacOS14DirectFallsBackToTerminalApp() {
        // ADR-023: no built-in on macOS 14, so Direct falls back to Terminal.app.
        XCTAssertEqual(
            TerminalDispatch.resolve(preference: .builtIn, customCommand: "",
                                     builtInAvailable: false, externalAllowed: true),
            .external(.terminalApp))
    }

    func testBuiltInPreferenceMacOS14AppStoreIsUnavailable() {
        // App Store has no external option; explain the macOS-15 gate.
        XCTAssertEqual(
            TerminalDispatch.resolve(preference: .builtIn, customCommand: "",
                                     builtInAvailable: false, externalAllowed: false),
            .unavailable(reason: "The built-in terminal requires macOS 15 or later."))
    }

    func testTerminalAppPreferenceDirect() {
        XCTAssertEqual(
            TerminalDispatch.resolve(preference: .terminalApp, customCommand: "",
                                     builtInAvailable: true, externalAllowed: true),
            .external(.terminalApp))
    }

    func testITermPreferenceDirect() {
        XCTAssertEqual(
            TerminalDispatch.resolve(preference: .iTerm2, customCommand: "",
                                     builtInAvailable: true, externalAllowed: true),
            .external(.iTerm2))
    }

    func testExternalPreferenceInAppStoreDegradesToBuiltIn() {
        // Defensive: an external preference somehow present in the App Store build
        // (e.g. a migrated plist) degrades to the built-in terminal when possible.
        XCTAssertEqual(
            TerminalDispatch.resolve(preference: .terminalApp, customCommand: "",
                                     builtInAvailable: true, externalAllowed: false),
            .builtIn)
        XCTAssertEqual(
            TerminalDispatch.resolve(preference: .iTerm2, customCommand: "",
                                     builtInAvailable: false, externalAllowed: false),
            .unavailable(reason: "The built-in terminal requires macOS 15 or later."))
    }

    func testCustomPreferenceWithCommand() {
        XCTAssertEqual(
            TerminalDispatch.resolve(preference: .custom, customCommand: "open -a Ghostty",
                                     builtInAvailable: true, externalAllowed: true),
            .external(.custom(command: "open -a Ghostty")))
    }

    func testCustomPreferenceTrimsWhitespace() {
        XCTAssertEqual(
            TerminalDispatch.resolve(preference: .custom, customCommand: "  wezterm  ",
                                     builtInAvailable: true, externalAllowed: true),
            .external(.custom(command: "wezterm")))
    }

    func testCustomPreferenceEmptyIsUnavailable() {
        guard case .unavailable = TerminalDispatch.resolve(
            preference: .custom, customCommand: "   ",
            builtInAvailable: true, externalAllowed: true) else {
            return XCTFail("empty custom command should be unavailable")
        }
    }

    func testCustomPreferenceInAppStoreDegradesToBuiltIn() {
        XCTAssertEqual(
            TerminalDispatch.resolve(preference: .custom, customCommand: "x",
                                     builtInAvailable: true, externalAllowed: false),
            .builtIn)
    }

    // MARK: storage contract

    func testPreferenceRawValuesAreStableStorageKeys() {
        // These raw values are persisted in UserDefaults — pin them (a rename
        // would silently reset every user's choice).
        XCTAssertEqual(TerminalPreference.builtIn.rawValue, "builtIn")
        XCTAssertEqual(TerminalPreference.terminalApp.rawValue, "terminalApp")
        XCTAssertEqual(TerminalPreference.iTerm2.rawValue, "iTerm2")
        XCTAssertEqual(TerminalPreference.custom.rawValue, "custom")
        XCTAssertEqual(TerminalPreference(rawValue: "builtIn"), .builtIn)
        XCTAssertNil(TerminalPreference(rawValue: "bogus"))
    }
}
