import AppKit
import FerryCore
import SwiftTerm

/// What the bridge needs from a terminal session — `TerminalSession` in the
/// app, a stub in unit tests. Escape-sequence handling is SwiftTerm's job and
/// isn't tested here (ADR-023); the bridge is Ferry's own seam, so it is.
@available(macOS 15.0, *)
public protocol TerminalSessionDriving: Sendable {
    /// Bytes from the remote shell (already merged stdout+stderr — a PTY
    /// merges them anyway). One stream for the session's lifetime.
    var output: AsyncStream<Data> { get }
    /// Keystrokes to the shell's stdin.
    func send(_ data: Data) async
    /// Terminal geometry changed (sends the SSH `window-change` request).
    func resize(columns: Int, rows: Int) async
}

@available(macOS 15.0, *)
extension TerminalSession: TerminalSessionDriving {}

/// Glues a SwiftTerm `TerminalView` to a `TerminalSessionDriving` (M15.5,
/// ADR-023): delegate keystrokes → `send`, view resizes → `resize`, and the
/// session's output stream → `feed(byteArray:)` on the main actor (SwiftTerm's
/// requirement). Owned by the app's terminal controller alongside the session;
/// the view is held weakly so a closed panel/window tears down cleanly.
///
/// Nothing that passes through here is logged (rule 6).
@available(macOS 15.0, *)
@MainActor
public final class TerminalSessionBridge {
    private let session: any TerminalSessionDriving
    /// Bridge-owned: the same live `TerminalView` (emulator buffer included)
    /// is re-hosted when the terminal moves between the docked panel and a
    /// pop-out window (screen 7 note 2) — so it must outlive any single host.
    private(set) var view: TerminalView?
    private var pump: Task<Void, Never>?

    /// Title from the shell (OSC 0/2) — the panel/window header shows it.
    public var onTitleChange: ((String) -> Void)?

    /// Test seam: intercepts delivered output instead of feeding the view.
    var outputSink: ((Data) -> Void)?

    public init(session: any TerminalSessionDriving) {
        self.session = session
    }

    /// Returns the bridge's terminal view, creating and wiring it on first
    /// call. Later calls return the *same instance* (with the font refreshed),
    /// which is what lets pop-out/re-dock move a live shell without losing
    /// the emulator buffer — SwiftUI re-hosts the identical NSView.
    public func makeOrReuseView(font: NSFont) -> TerminalView {
        if let view {
            if view.font != font { view.font = font }
            return view
        }
        let view = TerminalView(frame: .zero)
        view.font = font
        view.configureNativeColors()
        attach(to: view)
        return view
    }

    /// Wires the view and starts pumping session output into it. Re-attaching
    /// is harmless.
    public func attach(to view: TerminalView) {
        self.view = view
        view.terminalDelegate = self
        startPump()
    }

    /// Stops the output pump (panel/window closed for good). The session's
    /// lifecycle belongs to its owner — this never terminates it.
    public func detach() {
        pump?.cancel()
        pump = nil
        view = nil
    }

    private func startPump() {
        guard pump == nil else { return }   // one pump per bridge; stream spans restarts
        pump = Task { [weak self] in
            guard let output = self?.session.output else { return }
            for await chunk in output {
                guard let self else { return }
                self.deliver(chunk)
            }
        }
    }

    func deliver(_ chunk: Data) {
        if let outputSink {
            outputSink(chunk)
        } else {
            view?.feed(byteArray: ArraySlice(chunk))
        }
    }
}

/// SwiftTerm calls its delegate on the main thread; the `@preconcurrency`
/// conformance keeps the bridge main-actor-isolated across that seam.
@available(macOS 15.0, *)
extension TerminalSessionBridge: @preconcurrency TerminalViewDelegate {
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        let session = self.session
        Task { await session.send(bytes) }
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let session = self.session
        Task { await session.resize(columns: newCols, rows: newRows) }
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        onTitleChange?(title)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func scrolled(source: TerminalView, position: Double) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    // requestOpenLink / bell / clipboardCopy / clipboardRead / iTermContent
    // keep SwiftTerm's default implementations.
}
