import SwiftUI
import FerryCore
import AppKit

/// Settings ▸ General (M16, DESIGN.md screen 5 — net-new UI, ADR-025):
/// default local folder, app appearance, and reopen-on-launch.
struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Key.defaultLocalFolder)
    private var defaultLocalFolder = ""
    @AppStorage(AppSettings.Key.appearance)
    private var appearanceRaw = AppSettings.Default.appearance.rawValue
    @AppStorage(AppSettings.Key.reopenLastConnections)
    private var reopenLastConnections = true
    @AppStorage(AppSettings.Key.defaultEditor)
    private var defaultEditor = ""

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent("Default local folder") {
                    HStack(spacing: 8) {
                        Text(displayFolder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(defaultLocalFolder.isEmpty ? .secondary : .primary)
                        Button("Choose…") { chooseFolder() }
                            .accessibilityIdentifier("settings.general.chooseFolder")
                        if !defaultLocalFolder.isEmpty {
                            Button("Clear") { defaultLocalFolder = "" }
                        }
                    }
                }
                Text("The local pane opens here when a connection doesn’t set its own start folder.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Appearance", selection: $appearanceRaw) {
                    Text("Light").tag(AppearancePreference.light.rawValue)
                    Text("Dark").tag(AppearancePreference.dark.rawValue)
                    Text("System").tag(AppearancePreference.system.rawValue)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.general.appearance")
            }

            Section("On launch") {
                Toggle("Reopen the connections that were open last time", isOn: $reopenLastConnections)
                    .accessibilityIdentifier("settings.general.reopen")
                Text("Reconnects each tab; you’re prompted for any credential that isn’t saved in the Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            #if !APPSTORE
            // Editor round-trip (M19) — Direct builds only (rule 5): launching
            // another app can't work in the App Store sandbox, so the picker is
            // absent there.
            Section("Editing") {
                LabeledContent("Default editor") {
                    HStack(spacing: 8) {
                        Text(displayEditor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(defaultEditor.isEmpty ? .secondary : .primary)
                        Button("Choose…") { chooseEditor() }
                            .accessibilityIdentifier("settings.general.chooseEditor")
                        if !defaultEditor.isEmpty {
                            Button("Clear") { defaultEditor = "" }
                        }
                    }
                }
                Text("Right-click a remote file and choose “Open in Editor” to edit it here; Ferry uploads your changes back on save. Leave as System default to use each file’s usual app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif

            SettingsFootnote()
        }
    }

    private var displayFolder: String {
        defaultLocalFolder.isEmpty ? "Home folder" : (defaultLocalFolder as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !defaultLocalFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (defaultLocalFolder as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            defaultLocalFolder = url.path
        }
    }

    #if !APPSTORE
    private var displayEditor: String {
        defaultEditor.isEmpty ? "System default" : FileManager.default.displayName(atPath: defaultEditor)
    }

    private func chooseEditor() {
        if let url = ExternalEditorLauncher.chooseEditorApplication() {
            defaultEditor = url.path
        }
    }
    #endif
}
