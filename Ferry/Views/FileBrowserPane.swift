import SwiftUI
import FerryCore
import QuickLook
import UniformTypeIdentifiers

/// Sort/display helpers for table columns (optionals aren't Comparable).
extension FileItem {
    var sortSize: Int64 { size ?? -1 }
    var sortModified: Date { modifiedAt ?? .distantPast }

    var kindLabel: String {
        if isSymlink { return "Alias" }
        if isDirectory { return "Folder" }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return "Document" }
        return UTType(filenameExtension: ext.lowercased())?.localizedDescription
            ?? "\(ext.uppercased()) File"
    }

    var sizeLabel: String {
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var modifiedLabel: String {
        guard let modifiedAt else { return "—" }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var iconName: String {
        if isSymlink { return "arrow.triangle.turn.up.right.diamond" }
        if isDirectory { return "folder.fill" }
        return "doc"
    }
}

/// One browser pane (DESIGN.md screen 1): header (scope + breadcrumbs +
/// hidden toggle), sortable file table, footer. Used for both sides.
struct FileBrowserPane: View {
    @Environment(ConnectionManagerModel.self) private var model
    let session: BrowserSession
    let pane: PaneModel
    /// Items dragged from the OTHER pane were dropped here (M8 transfers).
    var onDropItems: (([FileItem], PaneModel) -> Void)?
    /// File URLs dropped from Finder — or dragged from the local pane, which
    /// vends file URLs — were dropped here (M10). Enqueued as transfers.
    var onDropURLs: (([URL], PaneModel) -> Void)?

    // File-operation dialogs (M10), scoped to this pane.
    @State private var renameTarget: FileItem?
    @State private var renameText = ""
    @State private var deleteTargets: [FileItem] = []
    @State private var permissionsTarget: FileItem?
    @State private var quickLookURL: URL?

    /// Drag payload for REMOTE items (no file URL exists): "ferryitem|<kind>|<d/f>|<path>".
    static func dragPayload(for item: FileItem, in pane: PaneModel) -> String {
        "ferryitem|\(pane.kind == .local ? "local" : "remote")|\(item.isDirectory ? "d" : "f")|\(item.path)"
    }

    var body: some View {
        @Bindable var pane = pane
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Track the focused pane for the toolbar filter + nav buttons.
        .onTapGesture { session.activePaneKind = pane.kind }
        // Inter-pane drops from the REMOTE side arrive as string payloads…
        .dropDestination(for: String.self) { payloads, _ in
            handleDrop(payloads)
        }
        // …while Finder files and local-pane items arrive as file URLs (M10).
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            onDropURLs?(files, pane)
            return true
        }
        .alert("Problem in this pane", isPresented: paneErrorPresented) {
            Button("OK", role: .cancel) { pane.errorMessage = nil }
        } message: {
            Text(pane.errorMessage ?? "")
        }
        .alert("Rename “\(renameTarget?.name ?? "")”", isPresented: renamePresented) {
            TextField("New name", text: $renameText)
                .accessibilityIdentifier("rename.field")
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { commitRename() }
        }
        .confirmationDialog(deleteTitle, isPresented: deletePresented, titleVisibility: .visible) {
            Button(deleteButtonTitle, role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) { deleteTargets = [] }
        } message: {
            Text(deleteMessage)
        }
        .sheet(item: $permissionsTarget) { target in
            PermissionsEditorSheet(item: target) { permissions in
                Task { await pane.applyPermissions(permissions, to: target) }
            }
        }
        .quickLookPreview($quickLookURL)
    }

    private var paneErrorPresented: Binding<Bool> {
        Binding(get: { pane.errorMessage != nil },
                set: { if !$0 { pane.errorMessage = nil } })
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(pane.kind == .local ? "LOCAL" : "REMOTE · \(session.profile.name)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(pane.kind == .local ? Color.accentColor : Color.green)
            breadcrumbs
            Spacer(minLength: 4)
            if pane.isLoading { ProgressView().controlSize(.mini) }
            Toggle(isOn: hiddenBinding) {
                Image(systemName: "eye")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Show hidden files")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(pane.flashPathBar ? Color.yellow.opacity(0.35) : Color.clear)
        .animation(.easeOut(duration: 0.4), value: pane.flashPathBar)
    }

    private var hiddenBinding: Binding<Bool> {
        Binding(get: { pane.includeHidden }, set: { pane.includeHidden = $0 })
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Text("›").foregroundStyle(.tertiary).font(.caption)
                    }
                    Button(crumb.label) {
                        session.navigate(pane, to: crumb.path)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
                    .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                }
            }
        }
    }

    private var crumbs: [(label: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        var running = ""
        for component in pane.path.split(separator: "/") {
            running += "/\(component)"
            result.append((String(component), running))
        }
        return result
    }

    // MARK: Table

    private var filteredItems: [FileItem] {
        let items = pane.sortedItems
        let filter = session.filterText.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty, session.activePaneKind == pane.kind else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    @ViewBuilder
    private var table: some View {
        @Bindable var pane = pane
        Table(filteredItems, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 6) {
                    // Drag handle is the icon only: a whole-row .draggable
                    // swallows double-clicks and breaks folder navigation
                    // (ADR-013). Local items vend a file URL so they drag to
                    // Finder too (M10); remote items vend the string payload.
                    icon(for: item)
                    Text(item.name)
                }
                .opacity(item.isHidden ? 0.55 : 1)
            }
            .width(min: 140, ideal: 220)

            TableColumn("Size", value: \.sortSize) { item in
                Text(item.sizeLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Modified", value: \.sortModified) { item in
                Text(item.modifiedLabel).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)

            TableColumn(pane.kind == .remote ? "Perms" : "Kind", value: \.kindLabel) { item in
                if pane.kind == .remote {
                    Text(item.permissions?.symbolic ?? "—")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text(item.kindLabel).foregroundStyle(.secondary)
                }
            }
            .width(min: 70, ideal: 90)

            TableColumn("Owner", value: \.sortOwner) { item in
                Text(item.owner ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            fileContextMenu(for: pane.items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            guard let id = ids.first,
                  let item = pane.items.first(where: { $0.id == id }) else { return }
            if item.isDirectory {
                session.navigate(pane, to: item.path)
            } else {
                quickLook(item)
            }
        }
    }

    /// Icon = drag handle. Local items carry a file URL (Finder + upload to
    /// the remote pane); remote items carry the string payload (download).
    @ViewBuilder
    private func icon(for item: FileItem) -> some View {
        let image = Image(systemName: item.iconName)
            .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
        if pane.kind == .local {
            image.draggable(URL(fileURLWithPath: item.path))
        } else {
            image.draggable(Self.dragPayload(for: item, in: pane))
        }
    }

    // MARK: Context menu + file operations (M10)

    @ViewBuilder
    private func fileContextMenu(for items: [FileItem]) -> some View {
        if let item = items.first, items.count == 1 {
            if !item.isDirectory {
                Button("Quick Look") { quickLook(item) }
                Divider()
            }
            Button(transferVerb) { onDropItems?(items, pane) }
            Button("Rename…") { startRename(item) }
            Button("Permissions…") { permissionsTarget = item }
            Divider()
            Button("Delete…", role: .destructive) { deleteTargets = items }
        } else if !items.isEmpty {
            Button("\(transferVerb) \(items.count) Items") { onDropItems?(items, pane) }
            Divider()
            Button("Delete \(items.count) Items…", role: .destructive) { deleteTargets = items }
        }
    }

    /// Upload from the local pane, download from the remote pane — both send
    /// to the opposite pane's current directory via `onDropItems`.
    private var transferVerb: String { pane.kind == .local ? "Upload" : "Download" }

    private func quickLook(_ item: FileItem) {
        session.activePaneKind = pane.kind
        Task {
            if let url = await pane.previewURL(for: item) { quickLookURL = url }
        }
    }

    private func startRename(_ item: FileItem) {
        renameTarget = item
        renameText = item.name
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        let newName = renameText
        renameTarget = nil
        Task { await pane.rename(target, to: newName) }
    }

    private func commitDelete() {
        let items = deleteTargets
        deleteTargets = []
        Task { await pane.delete(items) }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { !deleteTargets.isEmpty }, set: { if !$0 { deleteTargets = [] } })
    }

    private var deleteTitle: String {
        if deleteTargets.count == 1 { return "Delete “\(deleteTargets[0].name)”?" }
        return "Delete \(deleteTargets.count) items?"
    }

    private var deleteButtonTitle: String {
        deleteTargets.count == 1 ? "Delete" : "Delete \(deleteTargets.count) Items"
    }

    private var deleteMessage: String {
        let hasFolder = deleteTargets.contains(where: \.isDirectory)
        let scope = pane.kind == .local ? "on this Mac" : "on the server"
        if hasFolder {
            return "Folders are deleted with all their contents. This can’t be undone — the items are removed \(scope), not moved to a Trash."
        }
        return "This can’t be undone — the item\(deleteTargets.count == 1 ? " is" : "s are") removed \(scope), not moved to a Trash."
    }

    /// Accepts drops originating from the opposite pane only.
    private func handleDrop(_ payloads: [String]) -> Bool {
        let otherKindTag = pane.kind == .local ? "remote" : "local"
        let otherPane = pane.kind == .local ? session.remote : session.local
        let items: [FileItem] = payloads.compactMap { payload in
            let parts = payload.split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count == 4, parts[0] == "ferryitem", parts[1] == otherKindTag else { return nil }
            let path = parts[3]
            return FileItem(name: (path as NSString).lastPathComponent,
                            path: path,
                            isDirectory: parts[2] == "d")
        }
        guard !items.isEmpty else { return false }
        onDropItems?(items, otherPane)
        return true
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("\(filteredItems.count) item\(filteredItems.count == 1 ? "" : "s")")
            Spacer()
            Text(footerDetail)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private var footerDetail: String {
        switch pane.kind {
        case .local:
            let values = try? URL(fileURLWithPath: pane.path)
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let free = values?.volumeAvailableCapacityForImportantUsage {
                return ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free"
            }
            return ""
        case .remote:
            return "SFTP · \(session.profile.host)"
        }
    }
}

private extension FileItem {
    var sortOwner: String { owner ?? "" }
}
