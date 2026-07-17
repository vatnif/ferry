import SwiftUI
import FerryCore

/// Import connections from `~/.ssh/config` (M11 checkpoint B; UI signed off in
/// DECISIONS.md — not part of the original mockups). A checklist of the hosts
/// parsed from the config; the user picks which to add. Chosen hosts land as
/// SFTP profiles under a new "Imported" folder. No secrets are read from the
/// config — passwords/key passphrases are prompted on first connect.
struct SSHImportSheet: View {
    let hosts: [ImportedSSHHost]
    /// Called with the user's selection when they tap Import.
    let onImport: ([ImportedSSHHost]) -> Void
    @Environment(\.dismiss) private var dismiss

    /// IDs of the hosts currently checked (all selected by default).
    @State private var selected: Set<ImportedSSHHost.ID>

    init(hosts: [ImportedSSHHost], onImport: @escaping ([ImportedSSHHost]) -> Void) {
        self.hosts = hosts
        self.onImport = onImport
        _selected = State(initialValue: Set(hosts.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from SSH Config").font(.headline)
                Text("~/.ssh/config").font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            List {
                ForEach(hosts) { host in
                    Toggle(isOn: binding(for: host)) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(host.alias)
                                Text(host.endpointSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if host.identityFile != nil {
                                Image(systemName: "key.fill")
                                    .foregroundStyle(.secondary)
                                    .help("Uses a private key")
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(height: 220)
            .accessibilityIdentifier("sshImport.list")

            HStack {
                Button(allSelected ? "Deselect All" : "Select All") {
                    selected = allSelected ? [] : Set(hosts.map(\.id))
                }
                .buttonStyle(.link)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("sshImport.cancel")
                Button("Import \(selected.count)") {
                    onImport(hosts.filter { selected.contains($0.id) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("sshImport.import")
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var allSelected: Bool { selected.count == hosts.count }

    private func binding(for host: ImportedSSHHost) -> Binding<Bool> {
        Binding(
            get: { selected.contains(host.id) },
            set: { on in
                if on { selected.insert(host.id) } else { selected.remove(host.id) }
            })
    }
}
