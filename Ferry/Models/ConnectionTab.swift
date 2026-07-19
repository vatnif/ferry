import SwiftUI
import FerryCore

/// One connection tab in the main window (DESIGN.md screen 1 tab strip, M16
/// checkpoint B / ADR-027). Each tab owns its own connection state via its
/// `phase`; a `.connected` phase holds a full `BrowserSession` (panes, queue,
/// tunnels, terminal are already per-session), so tabs are independent.
///
/// A tab keeps its `profileID` even when disconnected so it can render the
/// profile summary + a Connect button (the grey-dot state in the mockup) and
/// reconnect in place. `profileID` is nil only for a brand-new empty tab.
@MainActor @Observable
final class ConnectionTab: Identifiable {
    let id = UUID()
    var profileID: UUID?
    var phase: ConnectionManagerModel.ConnectionPhase

    init(profileID: UUID? = nil,
         phase: ConnectionManagerModel.ConnectionPhase = .idle) {
        self.profileID = profileID
        self.phase = phase
    }

    /// Green dot in the tab strip when connected, grey otherwise.
    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    /// The live session when connected (nil while idle/connecting).
    var session: BrowserSession? { phase.session }
}
