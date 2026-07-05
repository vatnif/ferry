import SwiftUI
import FerryCore

/// Detail column until the dual-pane browser lands in M7: an empty state, or
/// a summary card + stubbed Connect button for the selected profile.
struct DetailPlaceholderView: View {
    @Environment(ConnectionManagerModel.self) private var model

    var body: some View {
        switch model.connectionPhase {
        case .connected(let session):
            BrowserView(session: session)
        case .connecting(let name):
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(name)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .idle:
            if let id = model.selectedItemID, let profile = model.library.profile(withID: id) {
                ProfileSummaryView(profile: profile)
            } else {
                ContentUnavailableView {
                    Label("No Connection Selected", systemImage: "sailboat")
                } description: {
                    Text("Select a connection in the sidebar, or create one with the + button. Double-click a connection to connect.")
                }
            }
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
