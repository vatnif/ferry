import SwiftUI
import FerryCore

/// Add/edit form for a single port forward (M14). Not drawn in the mockups —
/// the natural editor behind screen 4's Add/Edit buttons; UI signed off with
/// ADR-021. SOCKS hides the destination fields (dynamic).
struct TunnelEditorSheet: View {
    let existing: TunnelConfiguration?
    let onSave: (TunnelConfiguration) -> Void
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var kind: TunnelConfiguration.Kind
    @State private var listenHost: String
    @State private var listenPort: String
    @State private var destinationHost: String
    @State private var destinationPort: String

    init(existing: TunnelConfiguration?,
         onSave: @escaping (TunnelConfiguration) -> Void,
         onDelete: (() -> Void)? = nil) {
        self.existing = existing
        self.onSave = onSave
        self.onDelete = onDelete
        _kind = State(initialValue: existing?.kind ?? .local)
        _listenHost = State(initialValue: existing?.listenHost ?? "127.0.0.1")
        _listenPort = State(initialValue: existing.map { String($0.listenPort) } ?? "")
        _destinationHost = State(initialValue: existing?.destinationHost ?? "")
        _destinationPort = State(initialValue: existing?.destinationPort.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Add Tunnel" : "Edit Tunnel").font(.headline)

            Form {
                Picker("Type", selection: $kind) {
                    Text("Local (local port → remote destination)").tag(TunnelConfiguration.Kind.local)
                    Text("Remote (remote port → local destination)").tag(TunnelConfiguration.Kind.remote)
                    Text("Dynamic SOCKS proxy").tag(TunnelConfiguration.Kind.socks)
                }
                .accessibilityIdentifier("tunnelEditor.type")

                Section("Listen") {
                    TextField("Host", text: $listenHost)
                        .accessibilityIdentifier("tunnelEditor.listenHost")
                    TextField("Port", text: $listenPort)
                        .accessibilityIdentifier("tunnelEditor.listenPort")
                }

                if kind != .socks {
                    Section("Destination") {
                        TextField("Host", text: $destinationHost)
                            .accessibilityIdentifier("tunnelEditor.destHost")
                        TextField("Port", text: $destinationPort)
                            .accessibilityIdentifier("tunnelEditor.destPort")
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if existing != nil, let onDelete {
                    Button("Delete", role: .destructive) { onDelete(); dismiss() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
                    .accessibilityIdentifier("tunnelEditor.save")
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private var listen: Int? { Int(listenPort).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var destination: Int? { Int(destinationPort).flatMap { (1...65535).contains($0) ? $0 : nil } }

    private var isValid: Bool {
        guard listen != nil, !listenHost.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if kind == .socks { return true }
        return destination != nil && !destinationHost.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        guard let listenPortValue = listen else { return }
        let isSocks = kind == .socks
        let tunnel = TunnelConfiguration(
            id: existing?.id ?? UUID(),
            kind: kind,
            listenHost: listenHost.trimmingCharacters(in: .whitespaces),
            listenPort: listenPortValue,
            destinationHost: isSocks ? nil : destinationHost.trimmingCharacters(in: .whitespaces),
            destinationPort: isSocks ? nil : destination,
            isEnabled: existing?.isEnabled ?? true)
        onSave(tunnel)
        dismiss()
    }
}
