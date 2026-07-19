import SwiftUI
import FerryCore
import AppKit

/// Settings ▸ Keys (M16, DESIGN.md screen 5 — net-new UI, ADR-025): the SSH
/// keys in `~/.ssh`, key generation/import (Direct only), the ssh-agent option
/// (shown disabled — still backlogged, ADR-017), and management of Ferry's own
/// trusted host keys.
struct KeysSettingsView: View {
    @Environment(ConnectionManagerModel.self) private var model

    @State private var keys: [SSHKeyTools.KeyEntry] = []
    @State private var trustedHostCount = 0
    @State private var showKnownHosts = false
    @State private var errorMessage: String?
    #if !APPSTORE
    @State private var showGenerate = false
    #endif

    var body: some View {
        SettingsForm {
            Section("SSH keys") {
                if keys.isEmpty {
                    Text(keysEmptyMessage)
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(keys) { key in
                        LabeledContent {
                            Text("\(key.type) · ~/.ssh").font(.caption).foregroundStyle(.secondary)
                        } label: {
                            Text(key.name).font(.body.monospaced())
                        }
                    }
                }

                HStack {
                    #if !APPSTORE
                    Button("Generate…") { showGenerate = true }
                        .accessibilityIdentifier("settings.keys.generate")
                    Button("Import…") { importKey() }
                        .accessibilityIdentifier("settings.keys.import")
                    #else
                    Button("Generate…") {}.disabled(true)
                        .help("Key generation isn't available in the App Store build.")
                    Button("Import…") {}.disabled(true)
                        .help("Key import isn't available in the App Store build.")
                    #endif
                    Button("Reveal in Finder") { revealSSHFolder() }
                        .accessibilityIdentifier("settings.keys.reveal")
                }
                Text("Ed25519 and RSA OpenSSH keys. Generating writes a new keypair to **~/.ssh**; passphrases live in the Keychain, never in Ferry's files.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("SSH Agent") {
                Toggle(isOn: .constant(false)) {
                    Text("Authenticate through ssh-agent")
                    Text("Planned for a later release.")
                }
                .disabled(true)
            }

            Section("Known hosts") {
                LabeledContent("Trusted host keys") {
                    HStack(spacing: 10) {
                        Text("\(trustedHostCount)").foregroundStyle(.secondary)
                        Button("Manage…") { showKnownHosts = true }
                            .accessibilityIdentifier("settings.keys.manageHosts")
                    }
                }
                Text("Ferry's own trust store. Your **~/.ssh/known_hosts** is also read (never written) so hosts you already know skip the prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SettingsFootnote()
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $showKnownHosts, onDismiss: reload) {
            KnownHostsManagerSheet(store: model.hostKeyStore)
        }
        #if !APPSTORE
        .sheet(isPresented: $showGenerate, onDismiss: reload) {
            GenerateKeySheet { errorMessage = $0 }
        }
        #endif
        .alert("Couldn't complete that", isPresented: errorPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var keysEmptyMessage: String {
        #if APPSTORE
        return "No keys found. (The App Store build can't read ~/.ssh.)"
        #else
        return "No keys found in ~/.ssh."
        #endif
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func reload() {
        keys = SSHKeyTools.listKeys()
        trustedHostCount = (try? model.hostKeyStore.allTrustedHosts().count) ?? 0
    }

    private func revealSSHFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([SSHKeyTools.sshDirectoryURL])
    }

    #if !APPSTORE
    private func importKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an OpenSSH private key to copy into ~/.ssh"
        panel.directoryURL = SSHKeyTools.sshDirectoryURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SSHKeyTools.importKey(from: url)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif
}

#if !APPSTORE
/// A small sheet collecting the fields for `ssh-keygen` (Direct only, M16).
private struct GenerateKeySheet: View {
    let onError: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = "id_ed25519_ferry"
    @State private var type = SSHKeyTools.KeyType.ed25519
    @State private var passphrase = ""
    @State private var comment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generate SSH Key").font(.headline)
            Form {
                TextField("File name", text: $name)
                    .accessibilityIdentifier("generateKey.name")
                Picker("Type", selection: $type) {
                    ForEach(SSHKeyTools.KeyType.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                SecureField("Passphrase (optional)", text: $passphrase)
                TextField("Comment (optional)", text: $comment,
                          prompt: Text("e.g. you@mac"))
            }
            .formStyle(.grouped)
            Text("The key is written to ~/.ssh/\(name). A passphrase protects it and is never stored by Ferry.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Generate") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("generateKey.generate")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func generate() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        dismiss()
        do {
            try SSHKeyTools.generate(name: trimmed, type: type,
                                     passphrase: passphrase, comment: comment)
        } catch {
            onError(error.localizedDescription)
        }
    }
}
#endif
