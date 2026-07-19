import SwiftUI
import AppKit
import FerryCore

/// Applies the Settings ▸ General appearance choice (Light/Dark/System)
/// app-wide via `NSApp.appearance` (M16). AppKit — not SwiftUI's
/// `preferredColorScheme`, which at a WindowGroup's root re-creates the window
/// and breaks XCUITest's launch snapshot. `.system` clears the override (follow
/// macOS). Call from the main window's `onAppear` + on the setting's change.
enum FerryAppearance {
    static func apply(_ raw: String) {
        let appearance: NSAppearance?
        switch AppearancePreference(rawValue: raw) ?? .system {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appearance
    }
}

/// Shared building blocks for the Settings window tabs (M16, DESIGN.md
/// screen 5). Kept small so each tab view reads as a form.

/// A macOS-style radio row: filled circle when selected, tappable label, an
/// optional trailing hint, and an optional disabled explainer. Used by the
/// Terminal tab's "Open terminal sessions in" group (the approved tab-7 UI).
struct RadioRow: View {
    let title: String
    let isSelected: Bool
    var isDisabled: Bool = false
    var note: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected && !isDisabled ? Color.accentColor : Color.secondary)
                Text(title)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

/// A form section header + the standard settings body padding, so every tab
/// shares the same layout language (mockup screen 5).
struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}

/// The "Changes apply immediately" footer note shown on every tab (mockup).
struct SettingsFootnote: View {
    var body: some View {
        HStack {
            Spacer()
            Text("Changes apply immediately")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
