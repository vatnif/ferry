import AppKit
import SwiftTerm
import SwiftUI

/// SwiftUI host for SwiftTerm's `TerminalView` (M15.5, DESIGN.md screen 7).
/// The caller (the app's terminal controller) owns the bridge + session pair;
/// this view only hosts and styles the emulator.
///
/// Colors come from `configureNativeColors()` — the system's dynamic
/// text/background colors — so the terminal follows the app theme (screen 7
/// note 10). Font and scrollback come from Settings ▸ Terminal (M16, ADR-025)
/// and apply live — SwiftUI re-invokes `updateNSView` when the bound
/// `@AppStorage` values change.
@available(macOS 15.0, *)
public struct SSHTerminalView: NSViewRepresentable {
    private let bridge: TerminalSessionBridge
    private let font: NSFont
    private let scrollback: Int

    public init(bridge: TerminalSessionBridge,
                font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular),
                scrollback: Int = 10_000) {
        self.bridge = bridge
        self.font = font
        self.scrollback = scrollback
    }

    public func makeNSView(context: Context) -> TerminalView {
        // The bridge owns the view: hosting it here after a pop-out/re-dock
        // re-parents the SAME live emulator (buffer intact), per screen 7.
        bridge.makeOrReuseView(font: font, scrollback: scrollback)
    }

    public func updateNSView(_ view: TerminalView, context: Context) {
        if view.font != font {
            view.font = font
        }
        if view.getTerminal().options.scrollback != max(0, scrollback) {
            bridge.applyScrollback(scrollback, to: view)
        }
    }
}
