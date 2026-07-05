import SwiftUI
import FerryCore

/// The connected dual-pane workspace (DESIGN.md screen 1): toolbar,
/// local pane left + remote pane right, status bar. The transfer queue dock
/// arrives in M8; tabs in M16.
struct BrowserView: View {
    @Environment(ConnectionManagerModel.self) private var model
    let session: BrowserSession

    @State private var newFolderName: String?
    /// Conflicts awaiting the user's per-file decision (DOMAIN.md: Ask is
    /// the default exists-policy); the alert walks this list front to back,
    /// with Replace All / Skip All applying to the rest.
    @State private var pendingConflicts: [TransferRequest] = []

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            HSplitView {
                FileBrowserPane(session: session, pane: session.local) { items, sourcePane in
                    transfer(items, from: sourcePane)
                }
                .frame(minWidth: 300)
                FileBrowserPane(session: session, pane: session.remote) { items, sourcePane in
                    transfer(items, from: sourcePane)
                }
                .frame(minWidth: 300)
            }
            if !session.queue.rows.isEmpty {
                Divider()
                TransferQueueView(queue: session.queue)
            }
            Divider()
            statusBar
        }
        .alert("“\(pendingConflicts.first?.displayName ?? "")” already exists", isPresented: conflictsPresented) {
            Button("Replace", role: .destructive) {
                if let first = pendingConflicts.first { session.enqueueReplacing([first]) }
                pendingConflicts.removeFirst()
            }
            if pendingConflicts.count > 1 {
                Button("Replace All (\(pendingConflicts.count))", role: .destructive) {
                    session.enqueueReplacing(pendingConflicts)
                    pendingConflicts = []
                }
            }
            Button("Skip") { pendingConflicts.removeFirst() }
            Button(pendingConflicts.count > 1 ? "Skip All" : "Cancel", role: .cancel) {
                pendingConflicts = []
            }
        } message: {
            Text(conflictMessage)
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
                transferSelection(from: session.local)
            } label: {
                Label("Upload", systemImage: "arrow.up")
            }
            .disabled(session.local.selection.isEmpty)
            .accessibilityIdentifier("browser.upload")
            Button {
                transferSelection(from: session.remote)
            } label: {
                Label("Download", systemImage: "arrow.down")
            }
            .disabled(session.remote.selection.isEmpty)
            .accessibilityIdentifier("browser.download")

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
            healthIndicator
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

    /// Connection health (M9): green Connected / amber Reconnecting /
    /// red Connection lost with a manual retry.
    @ViewBuilder
    private var healthIndicator: some View {
        switch session.health {
        case .connected:
            Label {
                Text("Connected")
            } icon: {
                Circle().fill(.green).frame(width: 7, height: 7)
            }
            .accessibilityIdentifier("browser.status.connected")
        case .reconnecting(let attempt):
            Label {
                Text("Reconnecting (attempt \(attempt))…")
            } icon: {
                Circle().fill(.yellow).frame(width: 7, height: 7)
            }
            .accessibilityIdentifier("browser.status.reconnecting")
        case .lost:
            Label {
                Text("Connection lost")
            } icon: {
                Circle().fill(.red).frame(width: 7, height: 7)
            }
            .accessibilityIdentifier("browser.status.lost")
            Button("Reconnect") { session.reconnectNow() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    // MARK: Transfers

    private var conflictsPresented: Binding<Bool> {
        Binding(get: { !pendingConflicts.isEmpty }, set: { if !$0 { pendingConflicts = [] } })
    }

    private var conflictMessage: String {
        guard let first = pendingConflicts.first else { return "" }
        let what = first.kind == .directory
            ? "A folder with this name exists at \(first.destinationPath) — replacing merges its contents, overwriting same-named files."
            : "Replacing overwrites \(first.destinationPath). This cannot be undone."
        let remaining = pendingConflicts.count - 1
        return remaining > 0 ? "\(what)\n\(remaining) more conflict\(remaining == 1 ? "" : "s") after this one." : what
    }

    private func transferSelection(from pane: PaneModel) {
        let items = pane.items.filter { pane.selection.contains($0.id) }
        transfer(items, from: pane)
    }

    func transfer(_ items: [FileItem], from pane: PaneModel) {
        guard !items.isEmpty else { return }
        Task {
            let conflicts = await session.stageTransfers(items, from: pane)
            if !conflicts.isEmpty { pendingConflicts = conflicts }
        }
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
