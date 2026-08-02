import SwiftUI
import FerryCore

/// Window skeleton per DESIGN.md screen 1. In M4 the detail area is a
/// connection summary with a stubbed Connect button; the dual-pane browser
/// replaces it in M7.
struct MainWindow: View {
    @Environment(ConnectionManagerModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// Settings ▸ General appearance (M16), applied app-wide via NSApp.
    @AppStorage(AppSettings.Key.appearance) private var appearanceRaw = AppSettings.Default.appearance.rawValue
    /// The sidebar is the connection manager (DESIGN.md screen 1), so it must be
    /// on screen at launch. Left to `.automatic`, `NavigationSplitView` opened
    /// with the sidebar *hidden* — the window showed only the empty detail state
    /// and the connection list was reachable only via the toolbar's Show Sidebar
    /// (ADR-036). Driving the visibility keeps the user's in-session toggle.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TabStripView()
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            } detail: {
                DetailPlaceholderView()
            }
        }
        .background(closeTabShortcut)
        .sheet(item: $model.editorContext) { context in
            ConnectionEditorSheet(context: context)
        }
        .alert("Folder", isPresented: folderPromptPresented, presenting: model.folderPrompt) { prompt in
            FolderPromptFields(prompt: prompt)
        } message: { prompt in
            Text(prompt.renameFolderID == nil ? "Name the new folder." : "Enter a new name for the folder.")
        }
        .sheet(item: $model.passwordPrompt) { prompt in
            PasswordPromptSheet(prompt: prompt)
        }
        .sheet(item: $model.keyPassphrasePrompt) { prompt in
            KeyPassphrasePromptSheet(prompt: prompt)
        }
        .sheet(item: $model.hostKeyPrompt) { prompt in
            HostKeyPromptSheet(prompt: prompt)
        }
        .sheet(item: $model.certificatePrompt) { prompt in
            CertificatePromptSheet(prompt: prompt)
        }
        .sheet(item: $model.sshImport) { context in
            SSHImportSheet(hosts: context.hosts) { model.importSSHHosts($0) }
        }
        .sheet(item: $model.profileImport) { context in
            ProfileImportSheet(sourceName: context.sourceName, connections: context.connections) {
                model.importConnections($0, sourceName: context.sourceName)
            }
        }
        .sheet(item: $model.ferryImport) { context in
            FerryImportSheet(entries: context.entries) { model.importFerryEntries($0) }
        }
        .alert("Something went wrong", isPresented: errorPresented) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Not yet available", isPresented: infoPresented) {
            Button("OK", role: .cancel) { model.infoMessage = nil }
        } message: {
            Text(model.infoMessage ?? "")
        }
        .alert("Ferry", isPresented: noticePresented) {
            Button("OK", role: .cancel) { model.noticeMessage = nil }
        } message: {
            Text(model.noticeMessage ?? "")
        }
        // Closing a tab with running transfers confirms first (ADR-027).
        .alert("Transfers are still running", isPresented: tabClosePresented) {
            Button("Close Anyway", role: .destructive) {
                if let id = model.pendingTabClose { model.closeTab(id) }
                model.pendingTabClose = nil
            }
            Button("Keep Tab", role: .cancel) { model.pendingTabClose = nil }
        } message: {
            Text("This connection still has transfers in its queue. Closing the tab disconnects it and cancels them.")
        }
        // Models can't call openWindow — terminal-only connects (screen 7)
        // request their window through this hand-off.
        .onChange(of: model.pendingTerminalWindowID) { _, id in
            guard let id else { return }
            model.pendingTerminalWindowID = nil
            openWindow(id: "terminal", value: id)
        }
        // Reopen the connection open at last quit (Settings ▸ General, M16).
        .onAppear {
            FerryAppearance.apply(appearanceRaw)
            model.restoreLastConnectionsIfEnabled()
        }
        .onChange(of: appearanceRaw) { _, raw in FerryAppearance.apply(raw) }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var infoPresented: Binding<Bool> {
        Binding(get: { model.infoMessage != nil }, set: { if !$0 { model.infoMessage = nil } })
    }

    private var noticePresented: Binding<Bool> {
        Binding(get: { model.noticeMessage != nil }, set: { if !$0 { model.noticeMessage = nil } })
    }

    private var folderPromptPresented: Binding<Bool> {
        Binding(get: { model.folderPrompt != nil }, set: { if !$0 { model.folderPrompt = nil } })
    }

    private var tabClosePresented: Binding<Bool> {
        Binding(get: { model.pendingTabClose != nil }, set: { if !$0 { model.pendingTabClose = nil } })
    }

    /// ⌘W closes the active tab (not the window) — the window always keeps at
    /// least one tab (user decision 2026-07-19), so this never closes it. A
    /// zero-size hidden button owns the shortcut inside the key window.
    private var closeTabShortcut: some View {
        Button("Close Tab") { model.closeSelectedTab() }
            .keyboardShortcut("w", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

/// Connect-time password prompt (profile has no stored secret — DOMAIN.md
/// credential policy: empty stored password ⇒ ask, with remember opt-in).
private struct PasswordPromptSheet: View {
    @Environment(ConnectionManagerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let prompt: ConnectionManagerModel.PasswordPrompt
    @State private var password = ""
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Password for “\(prompt.profileName)”")
                .font(.headline)
            SecureField("Password", text: $password)
                .accessibilityIdentifier("passwordPrompt.password")
            Toggle("Remember in my Keychain", isOn: $remember)
                .font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    dismiss()
                    model.connectWithTypedPassword(password, prompt: prompt, remember: remember)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
                .accessibilityIdentifier("passwordPrompt.connect")
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Connect-time passphrase prompt for an encrypted SSH key (no stored
/// passphrase, or a stored/typed one was wrong). Same shape as the password
/// prompt, with an "incorrect" hint on retry.
private struct KeyPassphrasePromptSheet: View {
    @Environment(ConnectionManagerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let prompt: ConnectionManagerModel.KeyPassphrasePrompt
    @State private var passphrase = ""
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Passphrase for “\(prompt.profileName)”")
                .font(.headline)
            Text("This SSH key is encrypted. Enter its passphrase to unlock it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if prompt.incorrect {
                Text("That passphrase was incorrect. Try again.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            SecureField("Passphrase", text: $passphrase)
                .accessibilityIdentifier("passphrasePrompt.passphrase")
            Toggle("Remember in my Keychain", isOn: $remember)
                .font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock") {
                    dismiss()
                    model.connectWithTypedPassphrase(passphrase, prompt: prompt, remember: remember)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(passphrase.isEmpty)
                .accessibilityIdentifier("passphrasePrompt.unlock")
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Text field + actions inside the folder create/rename alert.
private struct FolderPromptFields: View {
    @Environment(ConnectionManagerModel.self) private var model
    let prompt: ConnectionManagerModel.FolderPrompt
    @State private var name: String

    init(prompt: ConnectionManagerModel.FolderPrompt) {
        self.prompt = prompt
        _name = State(initialValue: prompt.name)
    }

    var body: some View {
        TextField("Folder name", text: $name)
            .accessibilityIdentifier("folderPrompt.name")
        Button("Cancel", role: .cancel) { model.folderPrompt = nil }
        Button(prompt.renameFolderID == nil ? "Create" : "Rename") {
            if let renameID = prompt.renameFolderID {
                model.renameFolder(renameID, to: name)
            } else {
                model.createFolder(named: name, in: prompt.parentFolderID)
            }
            model.folderPrompt = nil
        }
    }
}
