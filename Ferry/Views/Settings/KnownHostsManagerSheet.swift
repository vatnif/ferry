import SwiftUI
import FerryCore

/// Manage Ferry's own trusted host keys (Settings ▸ Keys ▸ Manage…, M16).
/// Lists every endpoint in Ferry's `known_hosts` store with its fingerprint and
/// lets the user forget one (the next connect re-runs TOFU). Ferry's store only
/// — the user's `~/.ssh/known_hosts` is read-only pre-trust and isn't listed.
struct KnownHostsManagerSheet: View {
    let store: HostKeyStore
    @Environment(\.dismiss) private var dismiss

    @State private var hosts: [HostKeyStore.TrustedHost] = []
    @State private var toForget: HostKeyStore.TrustedHost?
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Known Hosts").font(.headline)
                Spacer()
                Text("\(hosts.count) trusted")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            if hosts.isEmpty {
                ContentUnavailableView("No trusted host keys",
                                       systemImage: "key",
                                       description: Text("Ferry hasn't stored any host keys yet. Keys you trust when connecting appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(hosts) { host in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.endpoint).font(.body.monospaced())
                                Text(host.key.displayFingerprint)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Forget", role: .destructive) { toForget = host }
                                .accessibilityIdentifier("knownHosts.forget")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Divider()
            HStack {
                if let loadError {
                    Text(loadError).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 360)
        .onAppear(perform: reload)
        .confirmationDialog("Forget this host key?",
                            isPresented: forgetPresented,
                            presenting: toForget) { host in
            Button("Forget \(host.endpoint)", role: .destructive) { forget(host) }
            Button("Cancel", role: .cancel) {}
        } message: { host in
            Text("Ferry will ask you to trust \(host.endpoint) again the next time you connect.")
        }
    }

    private var forgetPresented: Binding<Bool> {
        Binding(get: { toForget != nil }, set: { if !$0 { toForget = nil } })
    }

    private func reload() {
        do {
            hosts = try store.allTrustedHosts().sorted { $0.endpoint < $1.endpoint }
            loadError = nil
        } catch {
            loadError = "Couldn't read the known-hosts file."
        }
    }

    private func forget(_ host: HostKeyStore.TrustedHost) {
        try? store.remove(host: host.host, port: host.port)
        reload()
    }
}
