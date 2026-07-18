import AppKit
import SwiftTerm
import SwiftUI

/// SwiftUI host for SwiftTerm's `TerminalView` (M15.5, DESIGN.md screen 7).
/// The caller (the app's terminal controller) owns the bridge + session pair;
/// this view only hosts and styles the emulator.
///
/// Colors come from `configureNativeColors()` — the system's dynamic
/// text/background colors — so the terminal follows the app theme (screen 7
/// note 10). Scrollback configuration is wired in checkpoint C (Settings).
@available(macOS 15.0, *)
public struct SSHTerminalView: NSViewRepresentable {
    private let bridge: TerminalSessionBridge
    private let font: NSFont

    public init(bridge: TerminalSessionBridge,
                font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)) {
        self.bridge = bridge
        self.font = font
    }

    public func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.font = font
        view.configureNativeColors()
        bridge.attach(to: view)
        return view
    }

    public func updateNSView(_ view: TerminalView, context: Context) {
        if view.font != font {
            view.font = font
        }
    }
}
