import SwiftUI
import FerryCore
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
        .alert("Problem in this pane", isPresented: paneErrorPresented) {
            Button("OK", role: .cancel) { pane.errorMessage = nil }
        } message: {
            Text(pane.errorMessage ?? "")
        }
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
                    Image(systemName: item.iconName)
                        .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
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
        .contextMenu(forSelectionType: FileItem.ID.self) { _ in
            // File operations (rename/delete/chmod/Quick Look) arrive in M10.
        } primaryAction: { ids in
            guard let id = ids.first,
                  let item = pane.items.first(where: { $0.id == id }) else { return }
            if item.isDirectory {
                session.navigate(pane, to: item.path)
            } else {
                model.infoMessage = "Opening and transferring files arrives with the transfer queue (Milestone 8) and Quick Look (Milestone 10)."
            }
        }
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
