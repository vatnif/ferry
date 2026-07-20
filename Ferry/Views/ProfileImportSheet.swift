import SwiftUI
import FerryCore

/// Import connections from a competitor client — FileZilla, Cyberduck, or WinSCP
/// (M20 checkpoint A; UI signed off in DECISIONS.md, ADR-031). A checklist of the
/// connections parsed from the export; the user picks which to add. Chosen
/// connections land under a fresh "<Source> Import" folder, with the source
/// app's folder hierarchy rebuilt. No secrets are read — passwords/key
/// passphrases are prompted on first connect.
///
/// Generalized sibling of `SSHImportSheet` (M11), over `ImportedConnection`.
struct ProfileImportSheet: View {
    let sourceName: String
    let connections: [ImportedConnection]
    /// Called with the user's selection when they tap Import.
    let onImport: ([ImportedConnection]) -> Void
    @Environment(\.dismiss) private var dismiss

    /// IDs of the connections currently checked (all selected by default).
    @State private var selected: Set<ImportedConnection.ID>

    init(sourceName: String,
         connections: [ImportedConnection],
         onImport: @escaping ([ImportedConnection]) -> Void) {
        self.sourceName = sourceName
        self.connections = connections
        self.onImport = onImport
        _selected = State(initialValue: Set(connections.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from \(sourceName)").font(.headline)
                Text("Choose which connections to add. Passwords are not imported — "
                     + "you’ll be asked to enter them the first time you connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List {
                ForEach(connections) { connection in
                    Toggle(isOn: binding(for: connection)) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(connection.scheme.displayName)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(connection.name)
                                }
                                Text(pathAndEndpoint(connection))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if connection.identityFile != nil {
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
            .accessibilityIdentifier("profileImport.list")

            HStack {
                Button(allSelected ? "Deselect All" : "Select All") {
                    selected = allSelected ? [] : Set(connections.map(\.id))
                }
                .buttonStyle(.link)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("profileImport.cancel")
                Button("Import \(selected.count)") {
                    onImport(connections.filter { selected.contains($0.id) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("profileImport.import")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// Endpoint, prefixed with the source folder path when the connection was
    /// nested (so the user can tell same-named sites apart).
    private func pathAndEndpoint(_ connection: ImportedConnection) -> String {
        let path = connection.folderPathDisplay
        return path.isEmpty ? connection.endpointSummary
                            : "\(path)  ·  \(connection.endpointSummary)"
    }

    private var allSelected: Bool { selected.count == connections.count }

    private func binding(for connection: ImportedConnection) -> Binding<Bool> {
        Binding(
            get: { selected.contains(connection.id) },
            set: { on in
                if on { selected.insert(connection.id) } else { selected.remove(connection.id) }
            })
    }
}
