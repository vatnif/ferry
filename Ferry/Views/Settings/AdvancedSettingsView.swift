import SwiftUI
import FerryCore
import AppKit

/// Settings ▸ Advanced (M16, DESIGN.md screen 5 — net-new UI, ADR-025):
/// logging verbosity and an experimental-features flag.
struct AdvancedSettingsView: View {
    @AppStorage(AppSettings.Key.loggingLevel)
    private var loggingRaw = AppSettings.Default.loggingLevel.rawValue
    @AppStorage(AppSettings.Key.experimentalFeatures)
    private var experimental = false

    var body: some View {
        SettingsForm {
            Section {
                Picker("Logging", selection: $loggingRaw) {
                    Text("Off").tag(LoggingLevel.off.rawValue)
                    Text("Errors").tag(LoggingLevel.errors.rawValue)
                    Text("Verbose").tag(LoggingLevel.verbose.rawValue)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.advanced.logging")

                Button("Reveal Logs…") { openConsole() }
                    .accessibilityIdentifier("settings.advanced.revealLogs")
                Text("Ferry logs to the system log under **\(FerryLog.subsystem)** (open Console and filter by that subsystem). Passwords, key material and terminal contents are **never** logged.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Experimental") {
                Toggle("Enable experimental features", isOn: $experimental)
                    .accessibilityIdentifier("settings.advanced.experimental")
                Text("Off by default. Turns on in-progress features that aren't final; they may change or be removed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SettingsFootnote()
        }
    }

    private func openConsole() {
        let consoleURL = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open(consoleURL)
    }
}
