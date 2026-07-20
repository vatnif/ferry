import SwiftUI
import FerryCore

/// FTPS certificate trust dialog (DESIGN.md, ADR-033) — the TLS analog of
/// `HostKeyPromptSheet`. Two shapes share the sheet: first-contact TOFU (📜,
/// trust proceeds) and the changed-certificate alarm (⚠️, safe action primary,
/// replacing gated behind a second confirmation). There is no silent-accept path
/// (DOMAIN.md → FTP/FTPS).
struct CertificatePromptSheet: View {
    @Environment(ConnectionManagerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let prompt: ConnectionManagerModel.CertificatePrompt

    @State private var remember = true
    @State private var confirmingReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if prompt.isChanged { changedHeader } else { firstContactHeader }

            certificateBox(title: prompt.isChanged ? "New certificate (now)" : nil,
                           info: prompt.offered, identifier: "cert.offered")

            if prompt.isChanged, let previous = prompt.stored.first {
                certificateBox(title: "Previously trusted (was)", info: previous,
                               identifier: "cert.stored")
            }

            if !prompt.isChanged {
                Toggle("Remember this certificate", isOn: $remember)
                    .font(.callout)
                    .accessibilityIdentifier("cert.remember")
            }

            footer
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: Headers

    private var firstContactHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("📜").font(.system(size: 34))
            VStack(alignment: .leading, spacing: 4) {
                Text("Untrusted certificate for “\(prompt.profile.host)”")
                    .font(.headline)
                Text("This server’s TLS certificate is not signed by an authority your "
                     + "Mac trusts (it may be self-signed). Verify the fingerprint below "
                     + "matches the server you trust, then continue.")
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
                Text("Certificate has CHANGED")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("The certificate offered by “\(prompt.profile.host)” is different from "
                     + "the one you trusted before. This can mean the certificate was "
                     + "renewed — or that someone is intercepting the connection. Do not "
                     + "continue unless you know why it changed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Certificate detail

    private func certificateBox(title: String?, info: CertificateInfo, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                detailRow("Subject", info.subjectSummary)
                detailRow("Issuer", info.issuerSummary)
                detailRow("Valid", "\(info.notBefore) – \(info.notAfter)")
                Text(info.displayFingerprintLabel)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier(identifier)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        if prompt.isChanged {
            HStack {
                Button("Replace Certificate & Connect…", role: .destructive) { confirmingReplace = true }
                    .accessibilityIdentifier("cert.replace")
                    .confirmationDialog("Replace the trusted certificate for “\(prompt.profile.host)”?",
                                        isPresented: $confirmingReplace, titleVisibility: .visible) {
                        Button("Replace Certificate & Connect", role: .destructive) {
                            dismiss()
                            model.replaceCertificateAndConnect(prompt)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Only do this if you know the server’s certificate legitimately "
                             + "changed. If you are unsure, this could be an attack.")
                    }
                Spacer()
                Button("Disconnect (Recommended)") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("cert.disconnect")
            }
        } else {
            HStack {
                Button("Cancel", role: .destructive) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cert.cancel")
                Spacer()
                Button("Trust & Connect") {
                    dismiss()
                    model.trustCertificateAndConnect(prompt, remember: remember)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("cert.trust")
            }
        }
    }
}
