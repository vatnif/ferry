import SwiftUI
import FerryCore

/// The connected dual-pane workspace (DESIGN.md screen 1): toolbar,
/// local pane left + remote pane right, status bar. The transfer queue dock
/// arrives in M8; tabs in M16.
struct BrowserView: View {
    @Environment(ConnectionManagerModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let session: BrowserSession
    /// The tab hosting this session — the Disconnect toolbar action puts it
    /// back to the disconnected (grey-dot) state (M16 checkpoint B).
    let tab: ConnectionTab

    // The New Folder name, the staged conflicts / resume decisions (DOMAIN.md:
    // Ask is the default exists-policy; interrupted policy == Ask, M16) and the
    // tunnel sheet all live on the session, not in `@State`: this view has one
    // SwiftUI identity across every tab, so local state would follow the user
    // into another tab and act on the wrong connection (ADR-035).

    /// Baseline height while dragging the terminal panel's resize handle. Local
    /// on purpose — it only lives for the duration of one drag.
    @State private var terminalDragBase: CGFloat?
    /// Observed so the Terminal toolbar control re-resolves its dispatch the
    /// moment Settings ▸ Terminal changes (M16).
    @AppStorage(AppSettings.Key.terminalPreference)
    private var terminalPreferenceRaw = TerminalPreference.builtIn.rawValue
    @AppStorage(AppSettings.Key.terminalCustomCommand)
    private var terminalCustomCommand = ""

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            HSplitView {
                FileBrowserPane(
                    session: session, pane: session.local,
                    onDropItems: { items, sourcePane in transfer(items, from: sourcePane) },
                    onDropURLs: { urls, destinationPane in importFiles(urls, into: destinationPane) })
                .frame(minWidth: 300)
                FileBrowserPane(
                    session: session, pane: session.remote,
                    onDropItems: { items, sourcePane in transfer(items, from: sourcePane) },
                    onDropURLs: { urls, destinationPane in importFiles(urls, into: destinationPane) })
                .frame(minWidth: 300)
            }
            // Embedded terminal (screen 7): docked below the panes, above the
            // transfer queue; hidden while popped out into its own window.
            if #available(macOS 15.0, *), let terminal = session.terminal,
               terminal.isPanelVisible, !terminal.isWindowed {
                terminalResizeHandle(terminal)
                TerminalPanelView(
                    controller: terminal,
                    onPopOut: {
                        terminal.isWindowed = true
                        model.registerTerminalWindow(terminal)
                        openWindow(id: "terminal", value: terminal.id)
                    },
                    onCollapse: { terminal.isPanelVisible = false },
                    onClose: {
                        terminal.isPanelVisible = false
                        Task { await terminal.shutdown() }
                    })
                .frame(height: terminal.panelHeight)
                // Per-tab identity (ADR-035): every connected tab renders its
                // browser at the same structural position, so the panel needs an
                // explicit identity or SwiftUI carries one tab's panel — and its
                // local state — into the next.
                .id(terminal.id)
                // No container identifier: SwiftUI would propagate it to every
                // child, clobbering the panel controls' own identifiers.
            }
            if !session.queue.rows.isEmpty {
                Divider()
                TransferQueueView(queue: session.queue)
            }
            Divider()
            statusBar
        }
        .alert("“\(session.pendingConflicts.first?.displayName ?? "")” already exists", isPresented: conflictsPresented) {
            Button("Replace", role: .destructive) {
                if let first = session.pendingConflicts.first { session.enqueueReplacing([first]) }
                session.pendingConflicts.removeFirst()
            }
            if session.pendingConflicts.count > 1 {
                Button("Replace All (\(session.pendingConflicts.count))", role: .destructive) {
                    session.enqueueReplacing(session.pendingConflicts)
                    session.pendingConflicts = []
                }
            }
            Button("Skip") { session.pendingConflicts.removeFirst() }
            Button(session.pendingConflicts.count > 1 ? "Skip All" : "Cancel", role: .cancel) {
                session.pendingConflicts = []
            }
        } message: {
            Text(conflictMessage)
        }
        .alert("Resume “\(session.pendingResumeDecisions.first?.displayName ?? "")”?", isPresented: resumePresented) {
            Button("Resume") {
                if let first = session.pendingResumeDecisions.first { session.enqueueResuming([first.request]) }
                if !session.pendingResumeDecisions.isEmpty { session.pendingResumeDecisions.removeFirst() }
            }
            if session.pendingResumeDecisions.count > 1 {
                Button("Resume All (\(session.pendingResumeDecisions.count))") {
                    session.enqueueResuming(session.pendingResumeDecisions.map(\.request))
                    session.pendingResumeDecisions = []
                }
            }
            Button("Start Over", role: .destructive) {
                if let first = session.pendingResumeDecisions.first { session.enqueueReplacing([first.request]) }
                if !session.pendingResumeDecisions.isEmpty { session.pendingResumeDecisions.removeFirst() }
            }
            Button(session.pendingResumeDecisions.count > 1 ? "Skip All" : "Skip", role: .cancel) {
                session.pendingResumeDecisions = []
            }
        } message: {
            Text(resumeMessage)
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $session.showTunnels) {
            if let tunnels = session.tunnels {
                TunnelManagerSheet(profileID: session.profile.id, controller: tunnels)
                    .environment(model)
            }
        }
        .alert("New Folder", isPresented: newFolderPresented) {
            TextField("Folder name", text: newFolderBinding)
            Button("Cancel", role: .cancel) { session.newFolderName = nil }
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
            .help("Back to the previous folder in the active pane")
            Button {
                session.goForward(session.activePane)
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(session.activePane.forwardStack.isEmpty)
            .help("Forward to the next folder in the active pane")

            Button {
                transferSelection(from: session.local)
            } label: {
                Label("Upload", systemImage: "arrow.up")
            }
            .disabled(session.local.selection.isEmpty)
            .help("Upload the selected local files to the server")
            .accessibilityIdentifier("browser.upload")
            Button {
                transferSelection(from: session.remote)
            } label: {
                Label("Download", systemImage: "arrow.down")
            }
            .disabled(session.remote.selection.isEmpty)
            .help("Download the selected remote files to this Mac")
            .accessibilityIdentifier("browser.download")

            Button {
                session.newFolderName = ""
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("Create a new folder in the active pane")
            .accessibilityIdentifier("browser.newFolder")

            Button {
                Task {
                    await session.local.reload()
                    await session.remote.reload()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload both panes")
            .accessibilityIdentifier("browser.refresh")

            Toggle(isOn: linkedBinding) {
                Label("Linked", systemImage: "link")
            }
            .toggleStyle(.button)
            .help("Sync browsing: navigate both panes together")
            .accessibilityIdentifier("browser.linked")

            if session.tunnels != nil {
                Button {
                    session.showTunnels = true
                } label: {
                    Label("Tunnels", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .help("Manage port forwards for this connection")
                .accessibilityIdentifier("browser.tunnels")
            }

            // SSH profiles only (screen 7 note 5) — FTP/FTPS have no shell.
            if session.profile.scheme == .sftp || session.profile.scheme == .scp {
                terminalToolbarControl
            }

            TextField("Filter", text: $session.filterText, prompt: Text("Filter"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .help("Filter the file lists by name")
                .accessibilityIdentifier("browser.filter")

            Button {
                model.disconnect(tab)
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

    // MARK: Embedded terminal (screen 7, M15.5) + external hand-off (M15)

    /// The Terminal toolbar control dispatches on Settings ▸ Terminal (M15,
    /// ADR-024): built-in renders the accent-fill toggle for the docked panel;
    /// an external terminal renders a plain button that fires the hand-off; an
    /// unavailable configuration (macOS 14 App Store) shows a disabled button
    /// with the explainer as its tooltip.
    @ViewBuilder
    private var terminalToolbarControl: some View {
        let dispatch = TerminalLaunchService.dispatch(
            preference: TerminalPreference(rawValue: terminalPreferenceRaw) ?? .builtIn,
            customCommand: terminalCustomCommand)
        switch dispatch {
        case .builtIn:
            Toggle(isOn: terminalPanelBinding) {
                Label("Terminal", systemImage: "terminal")
            }
            .toggleStyle(.button)
            .help("Open a shell on the server")
            .accessibilityIdentifier("browser.terminal")
        case .external(let terminal):
            Button {
                model.launchExternalTerminal(terminal, profile: session.profile)
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .help("Open a shell on the server in \(terminal.displayName)")
            .accessibilityIdentifier("browser.terminal")
        case .unavailable(let reason):
            Button {} label: {
                Label("Terminal", systemImage: "terminal")
            }
            .disabled(true)
            .help(reason)
            .accessibilityIdentifier("browser.terminal")
        }
    }

    /// The Terminal toolbar toggle: accent-filled while the docked panel is
    /// open. When the terminal is popped out, clicking raises its window
    /// instead. On macOS 14 the built-in terminal is unavailable (the SSH
    /// library's PTY gate, ADR-023) — explain rather than half-work.
    private var terminalPanelBinding: Binding<Bool> {
        Binding(
            get: {
                guard #available(macOS 15.0, *), let terminal = session.terminal else { return false }
                return terminal.isPanelVisible && !terminal.isWindowed
            },
            set: { open in
                guard #available(macOS 15.0, *), let terminal = session.terminal else {
                    model.errorMessage = "The built-in terminal requires macOS 15 or later."
                    return
                }
                if terminal.isWindowed {
                    openWindow(id: "terminal", value: terminal.id)
                    return
                }
                terminal.isPanelVisible = open
                if open { terminal.ensureStarted() }
            })
    }

    /// Thin grab area above the panel; dragging resizes it (mockup note 1).
    @available(macOS 15.0, *)
    private func terminalResizeHandle(_ terminal: TerminalController) -> some View {
        Divider()
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = terminalDragBase ?? terminal.panelHeight
                                terminalDragBase = base
                                terminal.panelHeight = min(600, max(120, base - value.translation.height))
                            }
                            .onEnded { _ in terminalDragBase = nil })
                    .onHover { hovering in
                        if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    })
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
            if let tunnels = session.tunnels, tunnels.activeCount > 0 {
                Label("\(tunnels.activeCount) tunnel\(tunnels.activeCount == 1 ? "" : "s") active",
                      systemImage: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("browser.status.tunnels")
            }
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
        Binding(get: { !session.pendingConflicts.isEmpty }, set: { if !$0 { session.pendingConflicts = [] } })
    }

    /// Resume decisions wait until conflicts are cleared, so only one alert is
    /// ever on screen.
    private var resumePresented: Binding<Bool> {
        Binding(get: { session.pendingConflicts.isEmpty && !session.pendingResumeDecisions.isEmpty },
                set: { if !$0 { session.pendingResumeDecisions = [] } })
    }

    private var resumeMessage: String {
        guard let first = session.pendingResumeDecisions.first else { return "" }
        let bytes = ByteCountFormatter.string(fromByteCount: first.partialBytes, countStyle: .file)
        let base = "A partial download of \(bytes) exists. Resume continues from there; Start Over re-downloads from the beginning."
        let remaining = session.pendingResumeDecisions.count - 1
        return remaining > 0 ? "\(base)\n\(remaining) more after this one." : base
    }

    private var conflictMessage: String {
        guard let first = session.pendingConflicts.first else { return "" }
        let what = first.kind == .directory
            ? "A folder with this name exists at \(first.destinationPath) — replacing merges its contents, overwriting same-named files."
            : "Replacing overwrites \(first.destinationPath). This cannot be undone."
        let remaining = session.pendingConflicts.count - 1
        return remaining > 0 ? "\(what)\n\(remaining) more conflict\(remaining == 1 ? "" : "s") after this one." : what
    }

    private func transferSelection(from pane: PaneModel) {
        let items = pane.items.filter { pane.selection.contains($0.id) }
        transfer(items, from: pane)
    }

    func transfer(_ items: [FileItem], from pane: PaneModel) {
        guard !items.isEmpty else { return }
        Task {
            applyStaging(await session.stageTransfers(items, from: pane))
        }
    }

    /// Files dropped from Finder (or dragged from the local pane) into
    /// `destinationPane` — upload to the server or copy locally (M10).
    func importFiles(_ urls: [URL], into destinationPane: PaneModel) {
        guard !urls.isEmpty else { return }
        Task {
            applyStaging(await session.importFiles(urls, into: destinationPane))
        }
    }

    /// Surfaces whatever staging left for the user: conflicts first (exists
    /// policy Ask), then resume decisions (interrupted policy Ask, M16).
    private func applyStaging(_ result: BrowserSession.StagingResult) {
        session.pendingConflicts = result.conflicts
        session.pendingResumeDecisions = result.resumeDecisions
    }

    // MARK: New folder

    private var newFolderPresented: Binding<Bool> {
        Binding(get: { session.newFolderName != nil }, set: { if !$0 { session.newFolderName = nil } })
    }

    private var newFolderBinding: Binding<String> {
        Binding(get: { session.newFolderName ?? "" }, set: { session.newFolderName = $0 })
    }

    private func createFolder() {
        guard let name = session.newFolderName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            session.newFolderName = nil
            return
        }
        session.newFolderName = nil
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
