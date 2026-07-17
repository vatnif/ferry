import SwiftUI
import FerryCore

/// Screen 3 — host-key trust dialogs (DESIGN.md). Two shapes share the sheet:
/// first-contact TOFU (🔑, trust proceeds) and the changed-key alarm (⚠️, safe
/// action primary, replacing gated behind a second confirmation). There is no
/// silent-accept path (DOMAIN.md → Host key trust).
struct HostKeyPromptSheet: View {
    @Environment(ConnectionManagerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let prompt: ConnectionManagerModel.HostKeyPrompt

    @State private var remember = true
    @State private var confirmingReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if prompt.isChanged { changedHeader } else { firstContactHeader }

            fingerprintBox(title: prompt.isChanged ? "New key (now)" : nil,
                           info: prompt.offered, identifier: "hostKey.offered")

            if prompt.isChanged, let previous = prompt.stored.first {
                fingerprintBox(title: "Previously trusted (was)", info: previous,
                               identifier: "hostKey.stored")
            }

            if !prompt.isChanged {
                Toggle("Remember this key", isOn: $remember)
                    .font(.callout)
                    .accessibilityIdentifier("hostKey.remember")
            }

            footer
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: Headers

    private var firstContactHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("🔑").font(.system(size: 34))
            VStack(alignment: .leading, spacing: 4) {
                Text("Unknown server key for “\(prompt.profile.host)”")
                    .font(.headline)
                Text("Ferry has never connected to this server before. Confirm the "
                     + "fingerprint below matches the server you trust, then continue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var changedHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("⚠️").font(.system(size: 34))
            VStack(alignment: .leading, spacing: 4) {
                Text("Server key has CHANGED")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("The key offered by “\(prompt.profile.host)” is different from the one "
                     + "you trusted before. This can mean the server was reinstalled — or "
                     + "that someone is intercepting the connection. Do not continue unless "
                     + "you know why the key changed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Fingerprint

    private func fingerprintBox(title: String?, info: HostKeyInfo, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(info.displayFingerprint)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        if prompt.isChanged {
            HStack {
                Button("Replace Key & Connect…", role: .destructive) { confirmingReplace = true }
                    .accessibilityIdentifier("hostKey.replace")
                    .confirmationDialog("Replace the trusted key for “\(prompt.profile.host)”?",
                                        isPresented: $confirmingReplace, titleVisibility: .visible) {
                        Button("Replace Key & Connect", role: .destructive) {
                            dismiss()
                            model.replaceHostKeyAndConnect(prompt)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Only do this if you know the server's key legitimately changed. "
                             + "If you are unsure, this could be an attack.")
                    }
                Spacer()
                Button("Disconnect (Recommended)") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("hostKey.disconnect")
            }
        } else {
            HStack {
                Button("Cancel", role: .destructive) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("hostKey.cancel")
                Spacer()
                Button("Trust & Connect") {
                    dismiss()
                    model.trustHostKeyAndConnect(prompt, remember: remember)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("hostKey.trust")
            }
        }
    }
}
