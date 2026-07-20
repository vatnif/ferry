import SwiftUI
import FerryCore

/// Import connections from a competitor client — FileZilla, Cyberduck, or WinSCP
/// (M20 checkpoint A; UI signed off in DECISIONS.md, ADR-031). A thin adapter
/// mapping `ImportedConnection`s onto the shared `ImportChecklistSheet`. Chosen
/// connections land under a fresh "<Source> Import" folder, with the source
/// app's folder hierarchy rebuilt. No secrets are read — passwords/key
/// passphrases are prompted on first connect.
struct ProfileImportSheet: View {
    let sourceName: String
    let connections: [ImportedConnection]
    /// Called with the user's selection when they tap Import.
    let onImport: ([ImportedConnection]) -> Void

    var body: some View {
        ImportChecklistSheet(
            title: "Import from \(sourceName)",
            subtitle: "Choose which connections to add. Passwords are not imported — "
                    + "you’ll be asked to enter them the first time you connect.",
            idPrefix: "profileImport",
            rows: connections.map { connection in
                ImportChecklistSheet.Row(
                    id: connection.id,
                    scheme: connection.scheme.displayName,
                    title: connection.name,
                    detail: detail(connection),
                    usesKey: connection.identityFile != nil)
            },
            onImport: { ids in
                onImport(connections.filter { ids.contains($0.id) })
            })
    }

    /// Endpoint, prefixed with the source folder path when the connection was
    /// nested (so the user can tell same-named sites apart).
    private func detail(_ connection: ImportedConnection) -> String {
        let path = connection.folderPathDisplay
        return path.isEmpty ? connection.endpointSummary
                            : "\(path)  ·  \(connection.endpointSummary)"
    }
}
