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
