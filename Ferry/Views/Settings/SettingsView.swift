import SwiftUI

/// The Settings window (DESIGN.md screen 5, M16): a standard macOS settings
/// scene with the icon tab strip General · Transfers · Keys · Terminal ·
/// Advanced. Each tab is `@AppStorage`-backed, so "Changes apply immediately".
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .accessibilityIdentifier("settings.tab.general")
            TransfersSettingsView()
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
                .accessibilityIdentifier("settings.tab.transfers")
            KeysSettingsView()
                .tabItem { Label("Keys", systemImage: "key") }
                .accessibilityIdentifier("settings.tab.keys")
            TerminalSettingsView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .accessibilityIdentifier("settings.tab.terminal")
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "flask") }
                .accessibilityIdentifier("settings.tab.advanced")
        }
        .accessibilityIdentifier("settings.window")
    }
}
