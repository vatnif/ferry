import SwiftUI
import FerryCore
import FerryTerminalUI

/// The embedded terminal (DESIGN.md screen 7): header row, the SwiftTerm
/// host, and the session-ended banner. The same component serves the docked
/// panel and the standalone window — hosting differs, content doesn't.
@available(macOS 15.0, *)
struct TerminalPanelView: View {
    let controller: TerminalController
    /// Present in the docked panel only (⧉ in the header).
    var onPopOut: (() -> Void)?
    /// Present in a window that can return to its tab ("⇤ Dock in Window").
    var onRedock: (() -> Void)?
    /// Collapse (docked ⌄) or close-the-window; nil hides the control.
    var onCollapse: (() -> Void)?
    /// Terminate the shell (docked ✕) — confirmed while the shell is live.
    var onClose: (() -> Void)?

    @State private var confirmingClose = false

    // Settings ▸ Terminal (M16, ADR-025) — reactive: changing font or
    // scrollback in Settings updates every open terminal immediately.
    @AppStorage(AppSettings.Key.terminalFontName)
    private var fontName = AppSettings.Default.terminalFontName
    @AppStorage(AppSettings.Key.terminalFontSize)
    private var fontSize = AppSettings.Default.terminalFontSize
    @AppStorage(AppSettings.Key.terminalScrollbackLines)
    private var scrollbackLines = AppSettings.Default.terminalScrollbackLines

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            SSHTerminalView(bridge: controller.bridge,
                            font: TerminalAppearance.font(family: fontName, size: fontSize),
                            scrollback: scrollbackLines)
                // One emulator per controller, not per slot (ADR-035). SwiftUI
                // calls `makeNSView` once per identity, so without this the
                // docked panel — shared structurally by every connection tab —
                // keeps hosting the first tab's live TerminalView while its
                // `bridge` points at another tab's session: the wrong screen,
                // and keystrokes on the wrong server.
                .id(controller.id)
                .accessibilityIdentifier("terminal.view")
            if let ended = controller.endedMessage {
                endedBanner(ended)
            }
        }
        .confirmationDialog("End the shell session?", isPresented: $confirmingClose) {
            Button("End Session", role: .destructive) {
                onClose?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The shell on \(controller.endpoint) is still running. Closing the terminal ends it.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Terminal", systemImage: "terminal")
                .font(.caption.weight(.semibold))
            Text(controller.endpoint)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let title = controller.title, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            stateLabel
            Spacer()
            if let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: "rectangle.on.rectangle")
                }
                .help("Open in separate window")
                .accessibilityIdentifier("terminal.popOut")
            }
            if let onRedock {
                Button(action: onRedock) {
                    Label("Dock in Window", systemImage: "arrow.down.backward.square")
                }
                .help("Return the terminal to its connection window")
                .accessibilityIdentifier("terminal.redock")
            }
            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "chevron.down")
                }
                .help("Hide the terminal (the shell keeps running)")
                .accessibilityIdentifier("terminal.collapse")
            }
            if onClose != nil {
                Button {
                    if controller.isShellLive {
                        confirmingClose = true
                    } else {
                        onClose?()
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Close the terminal and end the shell")
                .accessibilityIdentifier("terminal.close")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch controller.state {
        case .idle, .connecting:
            Label {
                Text("connecting…")
            } icon: {
                Circle().fill(.yellow).frame(width: 7, height: 7)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("terminal.state.connecting")
        case .running:
            Label {
                Text("shell running")
            } icon: {
                Circle().fill(.green).frame(width: 7, height: 7)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("terminal.state.running")
        case .ended:
            Label {
                Text("session ended")
            } icon: {
                Circle().fill(.secondary).frame(width: 7, height: 7)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("terminal.state.ended")
        }
    }

    private func endedBanner(_ ended: (text: String, isFailure: Bool)) -> some View {
        HStack(spacing: 10) {
            Text(ended.text)
                .font(.callout)
                .foregroundStyle(ended.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            Spacer()
            Button {
                controller.ensureStarted()
            } label: {
                Label("Restart Session", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("terminal.restart")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.12))
        .overlay(Divider(), alignment: .top)
    }
}

/// Content of the standalone terminal window (pop-out and terminal-only
/// sessions, screen 7 notes 2 & 4). Looks the controller up by id — the
/// window survives its browser tab, but never the session itself: a missing
/// controller means the window has outlived what it showed, so it closes
/// (ADR-037). The scene opts out of state restoration for the same reason.
struct TerminalWindowView: View {
    @Environment(ConnectionManagerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controllerID: UUID?

    var body: some View {
        if #available(macOS 15.0, *),
           let id = controllerID,
           let controller = model.terminalWindow(id) {
            TerminalPanelView(
                controller: controller,
                onRedock: controller.canRedock ? {
                    controller.isWindowed = false
                    controller.isPanelVisible = true
                    model.removeTerminalWindow(id)
                    dismiss()
                } : nil)
            .navigationTitle("Terminal — \(controller.profileName)")
            .frame(minWidth: 480, minHeight: 280)
            .onDisappear {
                // Window closed. A re-dock already flipped isWindowed off and
                // deregistered; an actual close ends the session it owns.
                if controller.isWindowed {
                    model.removeTerminalWindow(id)
                    Task { await controller.shutdown() }
                }
            }
        } else {
            // No controller for this id: the window outlived the session it was
            // a view onto (a restored window after relaunch, or a re-dock that
            // deregistered before the dismiss landed). There is nothing to show
            // and nothing to reconnect to — close rather than leave a dead-end
            // window on screen (ADR-037).
            Color.clear
                .frame(minWidth: 480, minHeight: 280)
                .onAppear { dismiss() }
        }
    }
}
