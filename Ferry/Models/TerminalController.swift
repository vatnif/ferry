import SwiftUI
import FerryCore
import FerryTerminalUI

/// Main-actor projection of one embedded terminal (DESIGN.md screen 7,
/// ADR-023): owns the `TerminalSession` (its dedicated SSH session) and the
/// `TerminalSessionBridge` (which owns the live SwiftTerm view, so pop-out ↔
/// re-dock re-hosts the same emulator). One controller = one shell, whether
/// it's docked in a browser tab, popped out, or a terminal-only window.
///
/// macOS 15+ end to end (Citadel's `withPTY` gate, like SCP). The macOS-14
/// explainer lives at the entry points (`ConnectionManagerModel` / toolbar).
@available(macOS 15.0, *)
@MainActor @Observable
final class TerminalController: Identifiable {
    let id = UUID()
    let profileName: String
    /// "user@host" for the panel/window header (mono, per mockup).
    let endpoint: String
    /// Terminal-only sessions (sidebar "Open Terminal") have no browser tab,
    /// so the window never offers "Dock in Window".
    let standalone: Bool
    /// A popped-out terminal can return to its tab — until the tab
    /// disconnects (the window then survives and owns its session).
    var canRedock: Bool
    /// Docked panel visibility (per connection tab, mockup note 1).
    var isPanelVisible = false
    /// Hosted in its own window (pop-out or terminal-only)?
    var isWindowed = false
    /// Docked panel height — user-draggable (mockup note 1).
    var panelHeight: CGFloat = 220
    /// Shell-reported title (OSC 0/2), shown after the endpoint when present.
    private(set) var title: String?
    private(set) var state: TerminalSession.State = .idle

    let bridge: TerminalSessionBridge
    private let session: TerminalSession
    // nonisolated(unsafe): written once in init, cancelled in deinit.
    nonisolated(unsafe) private var stateTask: Task<Void, Never>?

    init(profile: ConnectionProfile,
         credential: SSHAuthCredential,
         hostKeyStore: HostKeyStore,
         systemKnownHosts: KnownHostsFile?,
         sessionTrusted: HostKeyInfo?,
         standalone: Bool) {
        self.profileName = profile.name
        self.endpoint = "\(profile.username)@\(profile.host)"
        self.standalone = standalone
        self.canRedock = !standalone
        let session = TerminalSession(host: profile.host,
                                      port: profile.port,
                                      username: profile.username,
                                      credential: credential,
                                      hostKeyStore: hostKeyStore,
                                      systemKnownHosts: systemKnownHosts,
                                      sessionTrusted: sessionTrusted)
        self.session = session
        self.bridge = TerminalSessionBridge(session: session)
        bridge.onTitleChange = { [weak self] newTitle in self?.title = newTitle }
        stateTask = Task { [weak self, session] in
            for await state in await session.states() {
                guard let self else { break }
                self.state = state
            }
        }
    }

    deinit {
        stateTask?.cancel()
    }

    var isShellLive: Bool { state == .running || state == .connecting }

    /// The ended-state banner's message, nil while the shell is up.
    var endedMessage: (text: String, isFailure: Bool)? {
        guard case .ended(let reason) = state else { return nil }
        switch reason {
        case .exited: return ("The shell session ended.", false)
        case .failed(let message): return (message, true)
        }
    }

    /// Starts the shell if it isn't live — first panel/window open, and the
    /// ended banner's Restart Session. Initial dims are nominal; SwiftTerm's
    /// first `sizeChanged` immediately resizes to the real geometry.
    func ensureStarted() {
        Task { await session.start(columns: 80, rows: 24) }
    }

    /// User-initiated close (panel ✕, window close, disconnect): ends the
    /// shell — reads as a clean exit, never a failure.
    func shutdown() async {
        await session.terminate()
    }
}
