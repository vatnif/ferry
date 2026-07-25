import SwiftUI
import FerryCore

/// New/Edit connection sheet per DESIGN.md screen 2. Field visibility adapts
/// to protocol and auth method; Test Connection runs a live TCP probe
/// (full protocol handshake supersedes it in M6).
struct ConnectionEditorSheet: View {
    @Environment(ConnectionManagerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let context: ConnectionManagerModel.EditorContext
    @State private var draft = ProfileDraft()
    @State private var loaded = false
    @State private var showKeyImporter = false
    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle, running
        case success(String)
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .accessibilityIdentifier("editor.name")
                    Picker("Save in folder", selection: $draft.folderID) {
                        Text("Top Level").tag(UUID?.none)
                        ForEach(model.library.allFolders) { folder in
                            Text(folder.name).tag(UUID?.some(folder.id))
                        }
                    }
                }

                Section {
                    Picker("Protocol", selection: schemeBinding) {
                        ForEach(TransferProtocol.allCases, id: \.self) { scheme in
                            Text(scheme.displayName).tag(scheme)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Server", text: $draft.host, prompt: Text("host or IP address"))
                        .accessibilityIdentifier("editor.host")
                    TextField("Port", value: $draft.port, format: .number.grouping(.never))
                        .accessibilityIdentifier("editor.port")
                    TextField("Username", text: $draft.username)
                        .accessibilityIdentifier("editor.username")
                }

                Section {
                    if draft.availableAuthChoices.count > 1 {
                        Picker("Authentication", selection: $draft.authChoice) {
                            ForEach(draft.availableAuthChoices) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    switch draft.authChoice {
                    case .password:
                        SecureField("Password", text: $draft.password)
                            .accessibilityIdentifier("editor.password")
                        keychainHint
                    case .publicKey:
                        HStack {
                            TextField("Private key", text: $draft.privateKeyPath,
                                      prompt: Text("~/.ssh/id_ed25519"))
                            Button("Choose…") { showKeyImporter = true }
                        }
                        SecureField("Key passphrase (optional)", text: $draft.keyPassphrase)
                        keychainHint
                    case .agent:
                        Text("Keys are provided by your running ssh-agent. Nothing is stored by Ferry.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Advanced") {
                    TextField("Remote start path", text: $draft.remoteStartPath,
                              prompt: Text("server default"))
                    TextField("Local start path", text: $draft.localStartPath,
                              prompt: Text("home folder"))
                        .accessibilityIdentifier("editor.localStart")
                    Toggle("Send keep-alive every 30 s and reconnect automatically",
                           isOn: $draft.keepAlive)
                    LabeledContent("Tunnels", value: "Configurable from Milestone 14")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Test Connection") { runTest() }
                    .disabled(testState == .running || draft.host.isEmpty)
                    .accessibilityIdentifier("editor.test")
                testResultView
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("editor.cancel")
                Button("Save") {
                    model.saveDraft(draft, existingID: context.profileID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
                .accessibilityIdentifier("editor.save")
            }
            .padding(14)
        }
        .frame(width: 560, height: 560)
        .navigationTitle(context.profileID == nil ? "New Connection" : "Edit Connection")
        .onAppear(perform: loadDraft)
        .fileImporter(isPresented: $showKeyImporter,
                      allowedContentTypes: [.data, .text, .item]) { result in
            if case .success(let url) = result {
                draft.privateKeyPath = url.path
            }
        }
    }

    private var keychainHint: some View {
        Text("Stored in the macOS Keychain — never written to Ferry’s files. Leave empty to be asked when connecting.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .lineLimit(1)
                .help(message)
        }
    }

    private var schemeBinding: Binding<TransferProtocol> {
        Binding(get: { draft.scheme }, set: { draft.switchScheme(to: $0) })
    }

    private func loadDraft() {
        guard !loaded else { return }
        loaded = true
        if let id = context.profileID, let profile = model.library.profile(withID: id) {
            // Reading the stored secret can block on a Keychain panel, so the
            // sheet fills in asynchronously rather than freezing (ADR-034).
            Task { draft = await ProfileDraft.fromExisting(profile, in: model) }
        } else {
            draft = ProfileDraft.forNewProfile(folderID: context.initialFolderID)
        }
    }

    private func runTest() {
        testState = .running
        let host = draft.host, port = draft.port
        Task {
            do {
                let result = try await ReachabilityProbe.tcpReachable(host: host, port: port)
                testState = .success(String(format: "Host reachable (%.2f s)", result.duration))
            } catch let error as ReachabilityProbe.ProbeError {
                switch error {
                case .invalidPort(let p):
                    testState = .failure("Invalid port \(p)")
                case .timedOut(let after):
                    testState = .failure(String(format: "No answer after %.0f s — check host and port", after))
                case .unreachable(let reason):
                    testState = .failure(reason)
                }
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
