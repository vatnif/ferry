import SwiftUI
import FerryCore

/// Window skeleton per DESIGN.md screen 1. In M4 the detail area is a
/// connection summary with a stubbed Connect button; the dual-pane browser
/// replaces it in M7.
struct MainWindow: View {
    @Environment(ConnectionManagerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            DetailPlaceholderView()
        }
        .sheet(item: $model.editorContext) { context in
            ConnectionEditorSheet(context: context)
        }
        .alert("Folder", isPresented: folderPromptPresented, presenting: model.folderPrompt) { prompt in
            FolderPromptFields(prompt: prompt)
        } message: { prompt in
            Text(prompt.renameFolderID == nil ? "Name the new folder." : "Enter a new name for the folder.")
        }
        .sheet(item: $model.passwordPrompt) { prompt in
            PasswordPromptSheet(prompt: prompt)
        }
        .alert("Something went wrong", isPresented: errorPresented) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Not yet available", isPresented: infoPresented) {
            Button("OK", role: .cancel) { model.infoMessage = nil }
        } message: {
            Text(model.infoMessage ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var infoPresented: Binding<Bool> {
        Binding(get: { model.infoMessage != nil }, set: { if !$0 { model.infoMessage = nil } })
    }

    private var folderPromptPresented: Binding<Bool> {
        Binding(get: { model.folderPrompt != nil }, set: { if !$0 { model.folderPrompt = nil } })
    }
}

/// Connect-time password prompt (profile has no stored secret — DOMAIN.md
/// credential policy: empty stored password ⇒ ask, with remember opt-in).
private struct PasswordPromptSheet: View {
    @Environment(ConnectionManagerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let prompt: ConnectionManagerModel.PasswordPrompt
    @State private var password = ""
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Password for “\(prompt.profileName)”")
                .font(.headline)
            SecureField("Password", text: $password)
                .accessibilityIdentifier("passwordPrompt.password")
            Toggle("Remember in my Keychain", isOn: $remember)
                .font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    dismiss()
                    model.connectWithTypedPassword(password,
                                                   profileID: prompt.profileID,
                                                   remember: remember)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
                .accessibilityIdentifier("passwordPrompt.connect")
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Text field + actions inside the folder create/rename alert.
private struct FolderPromptFields: View {
    @Environment(ConnectionManagerModel.self) private var model
    let prompt: ConnectionManagerModel.FolderPrompt
    @State private var name: String

    init(prompt: ConnectionManagerModel.FolderPrompt) {
        self.prompt = prompt
        _name = State(initialValue: prompt.name)
    }

    var body: some View {
        TextField("Folder name", text: $name)
            .accessibilityIdentifier("folderPrompt.name")
        Button("Cancel", role: .cancel) { model.folderPrompt = nil }
        Button(prompt.renameFolderID == nil ? "Create" : "Rename") {
            if let renameID = prompt.renameFolderID {
                model.renameFolder(renameID, to: name)
            } else {
                model.createFolder(named: name, in: prompt.parentFolderID)
            }
            model.folderPrompt = nil
        }
    }
}
