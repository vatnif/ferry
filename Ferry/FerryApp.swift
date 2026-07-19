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
                Button("New Tab") { model.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Import from SSH Config…") { model.beginSSHConfigImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            // Help ▸ Ferry Help + Acknowledgements… (M16 checkpoint C).
            HelpMenuCommands()
        }

        // Standalone terminal windows (screen 7, M15.5): pop-outs and
        // terminal-only sessions, keyed by controller id.
        WindowGroup("Terminal", id: "terminal", for: UUID.self) { $controllerID in
            TerminalWindowView(controllerID: controllerID)
                .environment(model)
        }
        .defaultSize(width: 640, height: 400)

        // In-app help + acknowledgements (Help menu, M16 checkpoint C,
        // ADR-028) — standalone single-instance windows so they are
        // XCUITest-drivable (the Settings scene isn't, ADR-025).
        Window("Ferry Help", id: "help") {
            HelpGuideWindowView()
        }
        .defaultSize(width: 600, height: 520)

        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsWindowView()
        }
        .defaultSize(width: 560, height: 480)

        // Settings window (screen 5, M16): General · Transfers · Keys ·
        // Terminal · Advanced. Reached via the app menu (⌘,).
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Replaces the default Help menu (a single non-functional "Ferry Help" search
/// item) with Ferry's own in-app guide + acknowledgements (M16 checkpoint C,
/// ADR-028). A `Commands` type reads `openWindow` from the environment so the
/// menu items can open the standalone windows declared above.
private struct HelpMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Ferry Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
            Button("Acknowledgements…") { openWindow(id: "acknowledgements") }
        }
    }
}
