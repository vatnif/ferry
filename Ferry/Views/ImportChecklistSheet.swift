import SwiftUI

/// Reusable import checklist (M20): a titled list of connections the user picks
/// from, with Select/Deselect All and an "Import N" action. The concrete
/// importers (competitor formats in checkpoint A, Ferry exports in checkpoint B)
/// adapt their parsed data into `Row`s and handle the chosen ids.
struct ImportChecklistSheet: View {
    struct Row: Identifiable, Hashable {
        let id: UUID
        /// Protocol tag (e.g. "SFTP").
        let scheme: String
        /// Primary line — the connection name.
        let title: String
        /// Secondary line — folder path and/or endpoint.
        let detail: String
        /// Shows the key badge when the connection uses a private key.
        let usesKey: Bool
    }

    let title: String
    let subtitle: String
    /// Accessibility-id prefix so each importer's sheet stays addressable
    /// (e.g. "profileImport" → profileImport.list/.import/.cancel).
    let idPrefix: String
    let rows: [Row]
    /// Called with the ids the user kept checked.
    let onImport: (Set<UUID>) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<UUID>

    init(title: String, subtitle: String, idPrefix: String, rows: [Row],
         onImport: @escaping (Set<UUID>) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.idPrefix = idPrefix
        self.rows = rows
        self.onImport = onImport
        _selected = State(initialValue: Set(rows.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List {
                ForEach(rows) { row in
                    Toggle(isOn: binding(for: row.id)) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(row.scheme)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(row.title)
                                }
                                if !row.detail.isEmpty {
                                    Text(row.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if row.usesKey {
                                Image(systemName: "key.fill")
                                    .foregroundStyle(.secondary)
                                    .help("Uses a private key")
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(height: 240)
            .accessibilityIdentifier("\(idPrefix).list")

            HStack {
                Button(allSelected ? "Deselect All" : "Select All") {
                    selected = allSelected ? [] : Set(rows.map(\.id))
                }
                .buttonStyle(.link)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("\(idPrefix).cancel")
                Button("Import \(selected.count)") {
                    onImport(selected)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("\(idPrefix).import")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var allSelected: Bool { selected.count == rows.count }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { on in
                if on { selected.insert(id) } else { selected.remove(id) }
            })
    }
}
