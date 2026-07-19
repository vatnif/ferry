import SwiftUI
import FerryCore

/// Detail column: the content of the selected connection tab (M16 checkpoint
/// B). A connected tab shows the dual-pane browser; a connecting tab a spinner;
/// an idle tab either its bound profile's summary (reconnect — the grey-dot
/// state) or, for a fresh empty tab, the profile selected in the sidebar (so a
/// single click still previews) or the empty state.
struct DetailPlaceholderView: View {
    @Environment(ConnectionManagerModel.self) private var model

    var body: some View {
        if let tab = model.selectedTab {
            content(for: tab)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func content(for tab: ConnectionTab) -> some View {
        switch tab.phase {
        case .connected(let session):
            BrowserView(session: session, tab: tab)
        case .connecting(let name):
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(name)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .idle:
            if let id = tab.profileID, let profile = model.library.profile(withID: id) {
                ProfileSummaryView(profile: profile)
            } else if let id = model.selectedItemID, let profile = model.library.profile(withID: id) {
                ProfileSummaryView(profile: profile)
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Connection Selected", systemImage: "sailboat")
        } description: {
            Text("Select a connection in the sidebar, or create one with the + button. Double-click a connection to connect (⌘-double-click opens it in a new tab).")
        }
    }
}

private struct ProfileSummaryView: View {
    @Environment(ConnectionManagerModel.self) private var model
    let profile: ConnectionProfile

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "server.rack")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            Text(profile.name)
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("Server").foregroundStyle(.secondary)
                    Text("\(profile.username)@\(profile.host):\(String(profile.port))")
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Protocol").foregroundStyle(.secondary)
                    Text(profile.scheme.displayName)
                }
                GridRow {
                    Text("Authentication").foregroundStyle(.secondary)
                    Text(authDescription)
                }
            }
            .font(.callout)

            HStack {
                Button("Edit…") { model.editorContext = .init(profileID: profile.id) }
                Button("Connect") {
                    model.connect(profileID: profile.id)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("detail.connect")
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var authDescription: String {
        switch profile.authMethod {
        case .password: "Password (Keychain)"
        case .publicKey(let path): "SSH key: \(path)"
        case .agent: "SSH agent"
        }
    }
}
