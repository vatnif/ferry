import Foundation

/// The content of the in-app user guide shown in the Ferry Help window (Help
/// menu, M16 checkpoint C, ADR-028). Pure and headless-testable: the prose
/// topics and the keyboard-shortcut reference live here so the app's SwiftUI
/// view only renders them, and a unit test can pin the shortcut list (every
/// entry names a key and an action, no duplicates).
///
/// Deliberately minimal (ROADMAP.md M16): the `.ferrypart`/resume explainer and
/// a keyboard-shortcut reference. A searchable/contextual help system is
/// backlog item 9.

/// One keyboard-shortcut reference row.
public struct HelpShortcut: Identifiable, Sendable, Hashable {
    public var id: String { keys + " · " + action }
    /// The key combination, formatted with the standard macOS glyphs (⌘⇧⌥⌃).
    public let keys: String
    /// What it does.
    public let action: String

    public init(keys: String, action: String) {
        self.keys = keys
        self.action = action
    }
}

/// One prose help topic (a heading + body paragraphs).
public struct HelpTopic: Identifiable, Sendable, Hashable {
    public var id: String { title }
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public enum HelpContent {
    /// The keyboard-shortcut reference (M16 checkpoint B added the tab
    /// shortcuts). ⌘-double-click is a mouse+modifier affordance, listed for
    /// discoverability even though it isn't a plain key equivalent.
    public static let shortcuts: [HelpShortcut] = [
        HelpShortcut(keys: "⌘T", action: "New tab"),
        HelpShortcut(keys: "⌘W", action: "Close the current tab"),
        HelpShortcut(keys: "⌘⇧I", action: "Import connections from ~/.ssh/config"),
        HelpShortcut(keys: "⌘,", action: "Open Settings"),
        HelpShortcut(keys: "⌘-double-click", action: "Open the selected connection in a new tab"),
        HelpShortcut(keys: "Double-click", action: "Connect (sidebar) or open a folder (file list)"),
        HelpShortcut(keys: "Space", action: "Quick Look the selected file"),
        HelpShortcut(keys: "⌘E", action: "Open the selected remote file in your editor"),
        HelpShortcut(keys: "⌘Q", action: "Quit Ferry")
    ]

    /// The prose topics, in reading order.
    public static let topics: [HelpTopic] = [
        HelpTopic(
            title: "Getting connected",
            body: """
            Add a connection with the + button under the sidebar, then double-click it \
            to connect in the current tab. ⌘-double-click opens it in a new tab so you \
            can browse several servers at once. Ferry supports SFTP, FTP, FTPS and SCP.

            The first time you connect to an SSH server, Ferry shows the server’s host-key \
            fingerprint and asks you to trust it (trust on first use). If a known server \
            ever offers a different key, Ferry warns you before continuing.

            FTPS servers work the same way for certificates. If a server’s TLS certificate \
            isn’t signed by an authority your Mac already trusts — for example a self-signed \
            or private-CA certificate — Ferry shows its fingerprint and asks you to trust it. \
            Once trusted, the certificate is pinned: Ferry checks for exactly that certificate \
            on every later connection and warns you if it ever changes. You can review or \
            forget trusted certificates in Settings ▸ Keys ▸ Trusted certificates.
            """),
        HelpTopic(
            title: "Importing connections",
            body: """
            Already using another client? Ferry can import your saved sites. Open the \
            Import Connections menu — under File, or from the Import button below the sidebar \
            — to read ~/.ssh/config (⌘⇧I) or bring in sites from FileZilla, Cyberduck or WinSCP.

            • FileZilla — choose your Site Manager file (sitemanager.xml); the folder \
            structure you set up is preserved.
            • Cyberduck — choose your Bookmarks folder.
            • WinSCP — in WinSCP on Windows, export your configuration to an INI file \
            (Tools ▸ Export/Backup Configuration), then choose that WinSCP.ini here.

            Ferry shows a checklist so you can pick which connections to add; they land in \
            a new folder named after the source. Passwords are never imported — you’ll be \
            asked for them the first time you connect. One caveat: WinSCP private keys are \
            in PuTTY’s .ppk format, which Ferry can’t read directly. Convert the key to \
            OpenSSH format and repoint the connection at it.

            To move connections between Macs, use Ferry’s own format: right-click a \
            connection or folder and choose Export… (or File ▸ Export All Connections…) to \
            save a .json file, then bring it in elsewhere with Import Connections ▸ From \
            Ferry Export…. The exported file contains your connection settings but no \
            passwords or keys, so it’s safe to share; imported connections arrive in a new \
            “Imported” folder without disturbing what you already have.
            """),
        HelpTopic(
            title: "Transferring files",
            body: """
            Drag files between the two panes, or use the Upload and Download toolbar \
            buttons, to add them to the transfer queue at the bottom of the window. The \
            queue runs several transfers at once (set the limit in Settings ▸ Transfers) \
            and shows progress, speed and estimated time for each item.

            You can also drag files and folders straight from the remote pane to a \
            Finder window: grab the row’s icon and drop it where you want it. The \
            download runs through the same transfer queue — watch its progress there — \
            and Finder shows the item only once it has fully arrived. If a file with the \
            same name is already at the drop location, Finder gives the new one a \
            numbered name, as it does for drags from other apps. Pausing the transfer in \
            Ferry lets Finder stop waiting, but the partial download is kept: press \
            Resume and the file still lands where you dropped it. Dropping files from \
            Finder onto a pane works in the other direction, adding uploads (or local \
            copies) to the queue.
            """),
        HelpTopic(
            title: "Resuming interrupted transfers",
            body: """
            Ferry downloads into a temporary file next to the destination with a \
            “.ferrypart” extension, and renames it into place only once the transfer \
            finishes. If a transfer is interrupted — the connection drops, or you quit — \
            the partial file is kept so the transfer can resume from where it left off \
            rather than starting over. Uploads resume the same way, continuing from the \
            size already on the server.

            When you start a transfer whose destination already has a matching partial, \
            Ferry can resume it, start over, or ask you each time — choose which in \
            Settings ▸ Transfers. Stale partials (older than 30 days, or larger than the \
            source) are discarded automatically. SCP is the exception: it cannot resume, \
            so an interrupted SCP transfer restarts.
            """),
        HelpTopic(
            title: "Tabs and windows",
            body: """
            Each tab is an independent connection with its own panes, transfer queue, \
            tunnels and terminal. Closing a tab disconnects it; if it still has running \
            transfers, Ferry asks first. Turn on “Reopen last connections” in Settings ▸ \
            General to have Ferry reconnect your open tabs at launch.
            """),
        HelpTopic(
            title: "The built-in terminal",
            body: """
            For SSH connections you can open a terminal on the server from the toolbar. \
            It runs inside Ferry on macOS 15 and later; on earlier systems, or if you \
            prefer, Settings ▸ Terminal can hand off to Terminal.app, iTerm2 or a custom \
            command instead. Pop the terminal out into its own window with the ⧉ button.
            """),
        HelpTopic(
            title: "Editing remote files",
            body: """
            Right-click a remote file and choose “Open in Editor” to edit it in your \
            preferred application, or “Open With” to pick a different app just this once. \
            Ferry downloads the file to a temporary copy, opens it, and watches it while \
            you work — every time you save, it uploads the changes back to the server \
            automatically. Each upload appears as an ordinary item in the transfer queue, \
            so you can see it complete. Set your preferred editor in Settings ▸ General.

            Editing sessions end when you disconnect or close the tab, and the temporary \
            copies are cleaned up then. This feature is available in the direct-download \
            build of Ferry; it isn’t offered in the App Store build, where apps can’t \
            launch other applications.
            """)
    ]
}
