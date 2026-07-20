import Foundation
import FerryCore

/// Reads the stored default-editor preference and resolves it against this
/// build's capabilities (Direct vs App Store), so the editor round-trip (M19)
/// dispatches consistently. Mirrors `TerminalLaunchService` (ADR-024). Always
/// compiled; the actual app launch lives in the Direct-only
/// `ExternalEditorLauncher` below.
enum EditorLaunchService {
    /// The Settings ▸ General default editor — an application file-URL path, or
    /// empty for "the system default app for the file's type".
    static var storedDefaultEditor: String {
        UserDefaults.standard.string(forKey: AppSettings.Key.defaultEditor) ?? ""
    }

    /// Whether editing in an external app is possible in this build. False in
    /// the sandboxed App Store build (launching other apps can't work, rule 5),
    /// which hides the "Open in Editor" / "Open With" menu items.
    static var externalAllowed: Bool {
        #if APPSTORE
        return false
        #else
        return true
        #endif
    }

    /// Resolve the editor for a file. `override` is a per-file "Open With ▸ app"
    /// choice (an application file-URL path) or nil to use the default.
    static func dispatch(override: String? = nil) -> EditorDispatch {
        EditorDispatch.resolve(defaultEditorPath: storedDefaultEditor,
                               override: override,
                               externalAllowed: externalAllowed)
    }
}

#if !APPSTORE
import AppKit
import UniformTypeIdentifiers

/// Launches an external editor for a file and enumerates candidate editors
/// (Direct builds only — launching other apps can't work in the App Store
/// sandbox, rule 5 / ADR-024, the `ExternalTerminalLauncher` precedent).
///
/// Not headless-testable (it drives `NSWorkspace`); the injection-free decision
/// logic it relies on lives in `EditorDispatch` and is unit-tested there.
enum ExternalEditorLauncher {

    /// One application offered in the "Open With ▸" submenu.
    struct EditorApp: Identifiable, Hashable {
        let url: URL
        var id: URL { url }
        let name: String
    }

    enum LaunchError: LocalizedError {
        case launchFailed(String)
        var errorDescription: String? {
            switch self {
            case .launchFailed(let message): return message
            }
        }
    }

    /// Applications that can open `fileURL`, for the "Open With ▸" submenu —
    /// de-duplicated and sorted by name. The system default (if any) is included
    /// by `NSWorkspace`.
    static func enumerateEditors(for fileURL: URL) -> [EditorApp] {
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        var seen = Set<URL>()
        var apps: [EditorApp] = []
        for url in urls where seen.insert(url).inserted {
            let name = FileManager.default.displayName(atPath: url.path)
            apps.append(EditorApp(url: url, name: name))
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "Other…" — pick an application from disk. Runs a modal open panel.
    @MainActor
    static func chooseEditorApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "Choose an application to edit with"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Open `fileURL` in the resolved editor and bring that app forward.
    static func launch(fileURL: URL, target: EditorTarget) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            switch target {
            case .systemDefault:
                _ = try await NSWorkspace.shared.open(fileURL, configuration: configuration)
            case .application(let path):
                let appURL = URL(fileURLWithPath: path)
                _ = try await NSWorkspace.shared.open([fileURL],
                                                      withApplicationAt: appURL,
                                                      configuration: configuration)
            }
        } catch {
            throw LaunchError.launchFailed(error.localizedDescription)
        }
    }
}
#endif
