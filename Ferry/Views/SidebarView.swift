import SwiftUI
import FerryCore
import UniformTypeIdentifiers

/// Connection-manager sidebar per DESIGN.md screen 1: folder tree with
/// protocol badges, context menus, drag-to-organize (drop on folders, or on
/// the "Connections" header for root), and a stubbed "This Mac" section that
/// becomes functional with the local pane in M5/M7.
struct SidebarView: View {
    @Environment(ConnectionManagerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedItemID) {
            Section {
                SidebarItemsView(items: model.library.items)
            } header: {
                Text("Connections")
                    .dropDestination(for: String.self) { ids, _ in
                        moveAll(ids, to: nil)
                    }
            }

            Section("This Mac") {
                Label("Home", systemImage: "house")
                Label("Downloads", systemImage: "arrow.down.circle")
            }
            .foregroundStyle(.secondary)
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first { SidebarItemMenu(itemID: id) }
        } primaryAction: { ids in
            // Double-click a profile ⇒ connect in the current tab; ⌘-double-click
            // ⇒ a new tab (DESIGN.md screen 1). primaryAction carries no modifier
            // flags, so read them from the current event.
            if let id = ids.first, model.library.profile(withID: id) != nil {
                let newTab = NSEvent.modifierFlags.contains(.command)
                model.connect(profileID: id, inNewTab: newTab)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.editorContext = .init(profileID: nil, initialFolderID: selectedFolderID)
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
                .accessibilityIdentifier("sidebar.newConnection")
                .help("New Connection")
            }
            ToolbarItem {
                Button {
                    model.folderPrompt = .init(parentFolderID: selectedFolderID)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("sidebar.newFolder")
                .help("New Folder")
            }
            ToolbarItem {
                Menu {
                    Button("From SSH Config…") { model.beginSSHConfigImport() }
                        .accessibilityIdentifier("sidebar.importSSHConfig")
                    Divider()
                    Button("From FileZilla…") { model.beginFileZillaImport() }
                        .accessibilityIdentifier("sidebar.importFileZilla")
                    Button("From Cyberduck…") { model.beginCyberduckImport() }
                        .accessibilityIdentifier("sidebar.importCyberduck")
                    Button("From WinSCP…") { model.beginWinSCPImport() }
                        .accessibilityIdentifier("sidebar.importWinSCP")
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("sidebar.import")
                .help("Import Connections")
            }
        }
    }

    /// New items land in the selected folder (or the selected profile's parent).
    private var selectedFolderID: UUID? {
        guard let id = model.selectedItemID else { return nil }
        if model.library.folder(withID: id) != nil { return id }
        return model.library.parentFolderID(ofItem: id)
    }

    private func moveAll(_ ids: [String], to folderID: UUID?) -> Bool {
        let uuids = ids.compactMap(UUID.init(uuidString:))
        guard !uuids.isEmpty else { return false }
        for id in uuids { model.moveItem(id, toFolder: folderID) }
        return true
    }
}

/// Recursive tree body. Folders are disclosure groups bound to the persisted
/// expansion state; every row is draggable by its UUID string.
struct SidebarItemsView: View {
    @Environment(ConnectionManagerModel.self) private var model
    let items: [SidebarItem]

    var body: some View {
        ForEach(items) { item in
            switch item {
            case .folder(let folder):
                DisclosureGroup(isExpanded: expansionBinding(folder)) {
                    SidebarItemsView(items: folder.items)
                } label: {
                    Label(folder.name, systemImage: "folder")
                        .draggable(folder.id.uuidString)
                        .dropDestination(for: String.self) { ids, _ in
                            let uuids = ids.compactMap(UUID.init(uuidString:))
                            guard !uuids.isEmpty else { return false }
                            for id in uuids { model.moveItem(id, toFolder: folder.id) }
                            return true
                        }
                }
                .tag(folder.id)
            case .profile(let profile):
                ProfileRow(profile: profile)
                    // Within-folder (and cross-folder) drag reorder — deferred
                    // from M4 to M16 (DESIGN.md). Dropping another item onto a
                    // profile row inserts it just before that row.
                    .dropDestination(for: String.self) { ids, _ in
                        guard let dragged = ids.compactMap(UUID.init(uuidString:)).first else { return false }
                        model.reorderItem(dragged, before: profile.id)
                        return true
                    }
                    .tag(profile.id)
            }
        }
    }

    private func expansionBinding(_ folder: ProfileFolder) -> Binding<Bool> {
        Binding(
            get: { model.library.folder(withID: folder.id)?.isExpanded ?? true },
            set: { model.setFolderExpanded(folder.id, $0) }
        )
    }
}

struct ProfileRow: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack {
            Label(profile.name, systemImage: "server.rack")
            Spacer()
            Text(profile.scheme.displayName)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.tertiary))
                .foregroundStyle(.secondary)
        }
        .draggable(profile.id.uuidString)
    }
}

/// Context menu for any sidebar item (profile or folder).
struct SidebarItemMenu: View {
    @Environment(ConnectionManagerModel.self) private var model
    let itemID: UUID

    var body: some View {
        if let profile = model.library.profile(withID: itemID) {
            Button("Edit…") { model.editorContext = .init(profileID: itemID) }
            Button("Duplicate") { model.duplicateProfile(itemID) }
            if profile.scheme == .sftp || profile.scheme == .scp {
                // Screen 7 note 4: a shell with no browser (SSH only — FTP
                // has none). macOS-14 explainer lives in openTerminal.
                Button("Open Terminal") { model.openTerminal(profileID: itemID) }
            }
            MoveToMenu(itemID: itemID)
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete() }
        } else if model.library.folder(withID: itemID) != nil {
            Button("New Connection Here") {
                model.editorContext = .init(profileID: nil, initialFolderID: itemID)
            }
            Button("New Folder Here") {
                model.folderPrompt = .init(parentFolderID: itemID)
            }
            Button("Rename…") {
                let current = model.library.folder(withID: itemID)?.name ?? ""
                model.folderPrompt = .init(renameFolderID: itemID, name: current)
            }
            MoveToMenu(itemID: itemID)
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete() }
        }
    }

    private func confirmDelete() {
        // Deleting removes Keychain secrets too — that's stated, not silent.
        let isFolder = model.library.folder(withID: itemID) != nil
        let name = isFolder
            ? model.library.folder(withID: itemID)?.name ?? "folder"
            : model.library.profile(withID: itemID)?.name ?? "connection"
        let alert = NSAlert()
        alert.messageText = isFolder
            ? "Delete the folder “\(name)” and everything inside it?"
            : "Delete the connection “\(name)”?"
        alert.informativeText = "Stored passwords of the affected connections are removed from the Keychain. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            model.deleteItem(itemID)
        }
    }
}

/// "Move to ▸" submenu: root + every folder (excluding a folder itself —
/// the library also guards against cycles).
struct MoveToMenu: View {
    @Environment(ConnectionManagerModel.self) private var model
    let itemID: UUID

    var body: some View {
        Menu("Move to") {
            Button("Top Level") { model.moveItem(itemID, toFolder: nil) }
            Divider()
            ForEach(model.library.allFolders.filter { $0.id != itemID }) { folder in
                Button(folder.name) { model.moveItem(itemID, toFolder: folder.id) }
            }
        }
    }
}
