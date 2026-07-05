import SwiftUI
import FerryCore

/// The connected dual-pane workspace (DESIGN.md screen 1): toolbar,
/// local pane left + remote pane right, status bar. The transfer queue dock
/// arrives in M8; tabs in M16.
struct BrowserView: View {
    @Environment(ConnectionManagerModel.self) private var model
    let session: BrowserSession

    @State private var newFolderName: String?

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            HSplitView {
                FileBrowserPane(session: session, pane: session.local)
                    .frame(minWidth: 300)
                FileBrowserPane(session: session, pane: session.remote)
                    .frame(minWidth: 300)
            }
            Divider()
            statusBar
        }
        .toolbar { toolbarContent }
        .alert("New Folder", isPresented: newFolderPresented) {
            TextField("Folder name", text: newFolderBinding)
            Button("Cancel", role: .cancel) { newFolderName = nil }
            Button("Create") { createFolder() }
        } message: {
            Text("Create a folder in the \(session.activePaneKind == .local ? "local" : "remote") pane at \(session.activePane.path)")
        }
    }

    // MARK: Toolbar (per mockup: nav, transfer stubs, folder, refresh, link, filter)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var session = session
        ToolbarItemGroup {
            Button {
                session.goBack(session.activePane)
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(session.activePane.backStack.isEmpty)
            Button {
                session.goForward(session.activePane)
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(session.activePane.forwardStack.isEmpty)

            Button {
                model.infoMessage = "Transfers arrive with the queue in Milestone 8."
            } label: {
                Label("Upload", systemImage: "arrow.up")
            }
            Button {
                model.infoMessage = "Transfers arrive with the queue in Milestone 8."
            } label: {
                Label("Download", systemImage: "arrow.down")
            }

            Button {
                newFolderName = ""
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .accessibilityIdentifier("browser.newFolder")

            Button {
                Task {
                    await session.local.reload()
                    await session.remote.reload()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("browser.refresh")

            Toggle(isOn: linkedBinding) {
                Label("Linked", systemImage: "link")
            }
            .toggleStyle(.button)
            .help("Sync browsing: navigate both panes together")
            .accessibilityIdentifier("browser.linked")

            TextField("Filter", text: $session.filterText, prompt: Text("Filter"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .accessibilityIdentifier("browser.filter")

            Button {
                model.disconnect()
            } label: {
                Label("Disconnect", systemImage: "eject")
            }
            .help("Disconnect from \(session.profile.name)")
            .accessibilityIdentifier("browser.disconnect")
        }
    }

    private var linkedBinding: Binding<Bool> {
        Binding(get: { session.linked }, set: { session.setLinked($0) })
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            Label {
                Text("Connected")
            } icon: {
                Circle().fill(.green).frame(width: 7, height: 7)
            }
            .accessibilityIdentifier("browser.status.connected")
            Text("\(session.profile.name) · \(session.profile.username)@\(session.profile.host):\(String(session.profile.port)) · \(session.profile.scheme.displayName)")
                .foregroundStyle(.secondary)
            if let ping = session.pingMilliseconds {
                Text("first listing \(ping) ms").foregroundStyle(.secondary)
            }
            if session.linked {
                Label("panes linked", systemImage: "link").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: New folder

    private var newFolderPresented: Binding<Bool> {
        Binding(get: { newFolderName != nil }, set: { if !$0 { newFolderName = nil } })
    }

    private var newFolderBinding: Binding<String> {
        Binding(get: { newFolderName ?? "" }, set: { newFolderName = $0 })
    }

    private func createFolder() {
        guard let name = newFolderName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            newFolderName = nil
            return
        }
        newFolderName = nil
        let pane = session.activePane
        let target = BrowserSession.join(pane.path, name)
        Task {
            do {
                try await pane.source.createDirectory(at: target)
                await pane.reload()
            } catch {
                pane.errorMessage = PaneModel.describe(error, path: target)
            }
        }
    }
}
