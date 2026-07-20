import SwiftUI
import FerryCore

/// Manage Ferry's pinned FTPS certificates (Settings ▸ Keys ▸ Manage…, ADR-033).
/// Lists every endpoint in Ferry's certificate trust store with its subject and
/// fingerprint and lets the user forget one (the next connect re-runs the cert
/// TOFU prompt). The TLS analog of `KnownHostsManagerSheet`.
struct TrustedCertsManagerSheet: View {
    let store: CertificateTrustStore
    @Environment(\.dismiss) private var dismiss

    @State private var certificates: [CertificateTrustStore.TrustedCertificate] = []
    @State private var toForget: CertificateTrustStore.TrustedCertificate?
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Trusted Certificates").font(.headline)
                Spacer()
                Text("\(certificates.count) trusted")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            if certificates.isEmpty {
                ContentUnavailableView("No trusted certificates",
                                       systemImage: "checkmark.seal",
                                       description: Text("Self-signed or private-CA FTPS certificates you trust when connecting appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(certificates) { cert in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cert.endpoint).font(.body.monospaced())
                                Text(cert.certificate.subjectSummary)
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(cert.certificate.displayFingerprintLabel)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Forget", role: .destructive) { toForget = cert }
                                .accessibilityIdentifier("trustedCerts.forget")
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
        .frame(width: 500, height: 380)
        .onAppear(perform: reload)
        .confirmationDialog("Forget this certificate?",
                            isPresented: forgetPresented,
                            presenting: toForget) { cert in
            Button("Forget \(cert.endpoint)", role: .destructive) { forget(cert) }
            Button("Cancel", role: .cancel) {}
        } message: { cert in
            Text("Ferry will ask you to trust \(cert.endpoint) again the next time you connect.")
        }
    }

    private var forgetPresented: Binding<Bool> {
        Binding(get: { toForget != nil }, set: { if !$0 { toForget = nil } })
    }

    private func reload() {
        do {
            certificates = try store.allTrustedCertificates()
            loadError = nil
        } catch {
            loadError = "Could not read the trusted-certificates file."
        }
    }

    private func forget(_ cert: CertificateTrustStore.TrustedCertificate) {
        try? store.remove(host: cert.host, port: cert.port)
        reload()
    }
}
