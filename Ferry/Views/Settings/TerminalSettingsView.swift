import SwiftUI
import FerryCore

/// Settings ▸ Terminal (mockup tab 7, approved 2026-07-18; wired in M16 over
/// M15's storage — ADR-024/025). Renders the built-in/external picker plus the
/// built-in font and scrollback controls. Everything is `@AppStorage`, so
/// changes apply live to open terminals and the browser toolbar.
struct TerminalSettingsView: View {
    @AppStorage(AppSettings.Key.terminalPreference)
    private var preferenceRaw = TerminalPreference.builtIn.rawValue
    @AppStorage(AppSettings.Key.terminalCustomCommand)
    private var customCommand = ""
    @AppStorage(AppSettings.Key.terminalFontName)
    private var fontName = AppSettings.Default.terminalFontName
    @AppStorage(AppSettings.Key.terminalFontSize)
    private var fontSize = AppSettings.Default.terminalFontSize
    @AppStorage(AppSettings.Key.terminalScrollbackLines)
    private var scrollbackLines = AppSettings.Default.terminalScrollbackLines

    private var preference: TerminalPreference {
        TerminalPreference(rawValue: preferenceRaw) ?? .builtIn
    }
    private var builtInAvailable: Bool { TerminalLaunchService.builtInAvailable }
    private var externalAllowed: Bool { TerminalLaunchService.externalAllowed }

    private let macOS15Note = "Requires macOS 15"

    var body: some View {
        SettingsForm {
            Section("Open terminal sessions in") {
                RadioRow(title: "Ferry’s built-in terminal",
                         isSelected: preference == .builtIn,
                         isDisabled: !builtInAvailable,
                         note: builtInAvailable ? nil : macOS15Note) {
                    preferenceRaw = TerminalPreference.builtIn.rawValue
                }

                // The three external options are Direct-only — launching other
                // apps can't work in the App Store sandbox (rule 5, ADR-024).
                if externalAllowed {
                    RadioRow(title: "Terminal.app",
                             isSelected: preference == .terminalApp) {
                        preferenceRaw = TerminalPreference.terminalApp.rawValue
                    }
                    RadioRow(title: "iTerm2",
                             isSelected: preference == .iTerm2) {
                        preferenceRaw = TerminalPreference.iTerm2.rawValue
                    }
                    RadioRow(title: "Custom command",
                             isSelected: preference == .custom) {
                        preferenceRaw = TerminalPreference.custom.rawValue
                    }
                    TextField("Custom command", text: $customCommand,
                              prompt: Text("e.g.  open -a Ghostty  (receives the ssh command)"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(preference != .custom)
                        .accessibilityIdentifier("settings.terminal.customCommand")
                }

                Text("External terminals are launched with an **ssh** command built from the profile — passwords are never passed; use key auth or type it there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Built-in terminal") {
                Picker("Font", selection: $fontName) {
                    ForEach(TerminalAppearance.fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .accessibilityIdentifier("settings.terminal.font")

                Stepper(value: $fontSize,
                        in: AppSettings.terminalFontSizeRange) {
                    Text("Size: \(fontSize) pt")
                }
                .accessibilityIdentifier("settings.terminal.fontSize")

                LabeledContent("Scrollback") {
                    HStack(spacing: 6) {
                        TextField("Scrollback", value: $scrollbackLines, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 90)
                            .accessibilityIdentifier("settings.terminal.scrollback")
                        Text("lines").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Text("Scrollback is kept **in memory only** — nothing you type or see is ever written to disk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!builtInAvailable)

            SettingsFootnote()
        }
    }
}
