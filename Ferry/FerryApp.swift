import SwiftUI
import FerryCore

@main
struct FerryApp: App {
    @State private var model = ConnectionManagerModel()

    var body: some Scene {
        WindowGroup("Ferry") {
            MainWindow()
                .environment(model)
        }
        .defaultSize(width: 980, height: 620)
        .commands {
            // Menu-bar equivalent of the sidebar's Import toolbar control
            // (M11 checkpoint B) — the canonical entry point; the toolbar item
            // may fold into the standard toolbar overflow on narrow windows.
            CommandGroup(after: .newItem) {
                Button("Import from SSH Config…") { model.beginSSHConfigImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        // Standalone terminal windows (screen 7, M15.5): pop-outs and
        // terminal-only sessions, keyed by controller id.
        WindowGroup("Terminal", id: "terminal", for: UUID.self) { $controllerID in
            TerminalWindowView(controllerID: controllerID)
                .environment(model)
        }
        .defaultSize(width: 640, height: 400)
    }
}
