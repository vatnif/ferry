import AppKit
import FerryCore

/// Resolves the Settings ▸ Terminal font choice (family name + size) into a
/// concrete `NSFont`, and offers the curated monospaced family list the
/// picker presents (M16, ADR-025). Shared by the terminal panel/window and
/// the Settings preview so both render the same font.
enum TerminalAppearance {

    /// Monospaced families offered in the picker. "SF Mono" is the default and
    /// the app's design font (DESIGN.md); the rest are macOS system installs so
    /// the choice always resolves.
    static let fontFamilies = ["SF Mono", "Menlo", "Monaco", "Courier New"]

    /// The `NSFont` for a stored (family, size). Falls back through the family
    /// manager to the system monospaced font, so an unknown/removed family name
    /// never yields a proportional font in a terminal.
    static func font(family: String, size: Int) -> NSFont {
        let points = CGFloat(clampSize(size))
        if let byName = NSFont(name: family, size: points) {
            return byName
        }
        if let byFamily = NSFontManager.shared.font(withFamily: family,
                                                    traits: [], weight: 5, size: points) {
            return byFamily
        }
        return .monospacedSystemFont(ofSize: points, weight: .regular)
    }

    static func clampSize(_ size: Int) -> Int {
        min(AppSettings.terminalFontSizeRange.upperBound,
            max(AppSettings.terminalFontSizeRange.lowerBound, size))
    }
}
