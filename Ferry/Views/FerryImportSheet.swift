import SwiftUI
import FerryCore

/// Import connections from a Ferry export file (M20 checkpoint B, ADR-032). A
/// thin adapter mapping the flattened `ImportEntry`s onto the shared
/// `ImportChecklistSheet`. Chosen connections land under a fresh "Imported"
/// folder with their exported folder structure rebuilt; every imported item
/// gets a fresh id so existing connections are never touched. No secrets are in
/// the file — passwords/passphrases are prompted on first connect.
struct FerryImportSheet: View {
    let entries: [ImportEntry]
    /// Called with the user's selection when they tap Import.
    let onImport: ([ImportEntry]) -> Void

    var body: some View {
        ImportChecklistSheet(
            title: "Import Connections",
            subtitle: "Choose which connections to add from this Ferry export. Passwords "
                    + "are not included — you’ll be asked to enter them on first connect.",
            idPrefix: "ferryImport",
            rows: entries.map { entry in
                ImportChecklistSheet.Row(
                    id: entry.profile.id,
                    scheme: entry.profile.scheme.displayName,
                    title: entry.profile.name,
                    detail: detail(entry),
                    usesKey: entry.profile.authMethod.usesPrivateKey)
            },
            onImport: { ids in
                onImport(entries.filter { ids.contains($0.profile.id) })
            })
    }

    private func detail(_ entry: ImportEntry) -> String {
        let endpoint = "\(entry.profile.username)@\(entry.profile.host):\(entry.profile.port)"
        let path = entry.folderPath.joined(separator: " / ")
        return path.isEmpty ? endpoint : "\(path)  ·  \(endpoint)"
    }
}
