import SwiftUI
import FerryCore

/// The connected dual-pane workspace (DESIGN.md screen 1): toolbar,
/// local pane left + remote pane right, status bar. The transfer queue dock
/// arrives in M8; tabs in M16.
struct BrowserView: View {
    @Environment(ConnectionManagerModel.self) private var model
    let session: BrowserSession

    @State private var newFolderName: String?
    @State private var pendingConflicts: [TransferRequest] = []
    @State private var skippedFolderCount = 0

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
        .alert("Replace existing files?", isPresented: conflictsPresented) {
            Button("Cancel", role: .cancel) { pendingConflicts = [] }
            Button("Replace", role: .destructive) {
                session.enqueueReplacing(pendingConflicts)
                pendingConflicts = []
            }
        } message: {
            Text(conflictMessage)
        }
        .alert("Folders skipped", isPresented: skippedPresented) {
            Button("OK", role: .cancel) { skippedFolderCount = 0 }
        } message: {
            Text("Folder transfers arrive in Milestone 9 — \(skippedFolderCount) folder\(skippedFolderCount == 1 ? " was" : "s were") skipped.")
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

    // MARK: Transfers

    private var conflictsPresented: Binding<Bool> {
        Binding(get: { !pendingConflicts.isEmpty }, set: { if !$0 { pendingConflicts = [] } })
    }

    private var skippedPresented: Binding<Bool> {
        Binding(get: { skippedFolderCount > 0 }, set: { if !$0 { skippedFolderCount = 0 } })
    }

    private var conflictMessage: String {
        let names = pendingConflicts.prefix(5).map(\.displayName).joined(separator: ", ")
        let extra = pendingConflicts.count > 5 ? " and \(pendingConflicts.count - 5) more" : ""
        return "\(names)\(extra) already exist\(pendingConflicts.count == 1 ? "s" : "") at the destination. Replacing cannot be undone."
    }

    private func transferSelection(from pane: PaneModel) {
        let items = pane.items.filter { pane.selection.contains($0.id) }
        transfer(items, from: pane)
    }

    func transfer(_ items: [FileItem], from pane: PaneModel) {
        guard !items.isEmpty else { return }
        Task {
            let result = await session.stageTransfers(items, from: pane)
            if !result.conflicts.isEmpty { pendingConflicts = result.conflicts }
            if result.skippedFolders > 0 { skippedFolderCount = result.skippedFolders }
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
