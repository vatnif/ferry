import AppKit
import SwiftTerm
import XCTest
@testable import FerryTerminalUI

/// The bridge is Ferry's own seam between SwiftTerm's `TerminalView` and a
/// `TerminalSession` — these tests drive it against a stub session (M15.5,
/// ADR-023). Escape-sequence handling is SwiftTerm's code and is deliberately
/// NOT tested here.
@available(macOS 15.0, *)
@MainActor
final class TerminalSessionBridgeTests: XCTestCase {

    private final class StubSession: TerminalSessionDriving, @unchecked Sendable {
        let output: AsyncStream<Data>
        let continuation: AsyncStream<Data>.Continuation
        private let lock = NSLock()
        private var _sent: [Data] = []
        private var _resizes: [[Int]] = []

        init() {
            (output, continuation) = AsyncStream<Data>.makeStream()
        }

        var sent: [Data] { lock.withLock { _sent } }
        var resizes: [[Int]] { lock.withLock { _resizes } }

        func send(_ data: Data) async { lock.withLock { _sent.append(data) } }
        func resize(columns: Int, rows: Int) async { lock.withLock { _resizes.append([columns, rows]) } }
    }

    /// Polls for `condition`, failing after a deadline — never waits on event
    /// arrival alone (the ADR-014 test lesson).
    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testKeystrokesForwardToSessionSend() async throws {
        let session = StubSession()
        let bridge = TerminalSessionBridge(session: session)
        let view = TerminalView(frame: .zero)
        bridge.attach(to: view)

        let typed: [UInt8] = Array("ls -la\n".utf8)
        bridge.send(source: view, data: typed[...])

        try await waitUntil("keystrokes to reach the session") { session.sent == [Data(typed)] }
    }

    func testSizeChangeForwardsToSessionResize() async throws {
        let session = StubSession()
        let bridge = TerminalSessionBridge(session: session)
        let view = TerminalView(frame: .zero)
        bridge.attach(to: view)

        bridge.sizeChanged(source: view, newCols: 132, newRows: 43)

        try await waitUntil("the resize to reach the session") { session.resizes == [[132, 43]] }
    }

    func testSessionOutputIsDeliveredInOrder() async throws {
        let session = StubSession()
        let bridge = TerminalSessionBridge(session: session)
        var delivered: [Data] = []
        bridge.outputSink = { delivered.append($0) }
        bridge.attach(to: TerminalView(frame: .zero))

        session.continuation.yield(Data("first ".utf8))
        session.continuation.yield(Data("second".utf8))

        try await waitUntil("both chunks to be delivered") { delivered.count == 2 }
        XCTAssertEqual(delivered, [Data("first ".utf8), Data("second".utf8)])
    }

    func testDetachStopsDelivery() async throws {
        let session = StubSession()
        let bridge = TerminalSessionBridge(session: session)
        var delivered: [Data] = []
        bridge.outputSink = { delivered.append($0) }
        bridge.attach(to: TerminalView(frame: .zero))

        session.continuation.yield(Data("before".utf8))
        try await waitUntil("the first chunk") { delivered.count == 1 }

        bridge.detach()
        session.continuation.yield(Data("after".utf8))
        // Give a wrongly-alive pump a real chance to misbehave.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(delivered, [Data("before".utf8)])
    }

    func testTitleChangeReachesCallback() async throws {
        let session = StubSession()
        let bridge = TerminalSessionBridge(session: session)
        let view = TerminalView(frame: .zero)
        var title: String?
        bridge.onTitleChange = { title = $0 }
        bridge.attach(to: view)

        bridge.setTerminalTitle(source: view, title: "deploy@prod-web-01: ~")

        XCTAssertEqual(title, "deploy@prod-web-01: ~")
    }

    func testMakeOrReuseViewReturnsTheSameLiveInstance() {
        // The pop-out ↔ re-dock contract (screen 7): re-hosting must get the
        // SAME view back so the emulator buffer survives the move.
        let bridge = TerminalSessionBridge(session: StubSession())
        let first = bridge.makeOrReuseView(font: .monospacedSystemFont(ofSize: 12, weight: .regular), scrollback: 5000)
        let second = bridge.makeOrReuseView(font: .monospacedSystemFont(ofSize: 14, weight: .regular), scrollback: 5000)
        XCTAssertTrue(first === second)
        XCTAssertEqual(second.font.pointSize, 14, "font refreshes on reuse")
    }

    func testEachBridgeOwnsItsOwnViewAndOutput() async throws {
        // Two terminals (two connection tabs, ADR-035) must never share an
        // emulator: each bridge makes its own view, and a session's output
        // reaches only that session's view. The SwiftUI half of the contract —
        // giving each controller its own view identity so `makeNSView` runs per
        // controller — is covered by FerryUITests.
        let sessionA = StubSession()
        let sessionB = StubSession()
        let bridgeA = TerminalSessionBridge(session: sessionA)
        let bridgeB = TerminalSessionBridge(session: sessionB)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let viewA = bridgeA.makeOrReuseView(font: font, scrollback: 1000)
        let viewB = bridgeB.makeOrReuseView(font: font, scrollback: 1000)
        XCTAssertFalse(viewA === viewB, "each bridge must own a distinct emulator")

        var deliveredA: [Data] = []
        var deliveredB: [Data] = []
        bridgeA.outputSink = { deliveredA.append($0) }
        bridgeB.outputSink = { deliveredB.append($0) }

        sessionA.continuation.yield(Data("from-a".utf8))
        try await waitUntil("A's chunk") { deliveredA.count == 1 }
        // Give a wrongly-crossed pump a real chance to misbehave.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(deliveredA, [Data("from-a".utf8)])
        XCTAssertTrue(deliveredB.isEmpty, "A's output must not reach B's view")

        // Keystrokes route by view, too.
        bridgeB.send(source: viewB, data: Array("whoami\n".utf8)[...])
        try await waitUntil("B's keystrokes") { sessionB.sent.count == 1 }
        XCTAssertTrue(sessionA.sent.isEmpty, "B's keystrokes must not reach A's shell")
    }

    func testScrollbackAppliesAndReasserts() {
        // The Settings scrollback (M16, ADR-025) reaches the emulator on
        // creation and survives a resize (the bridge re-asserts it).
        let bridge = TerminalSessionBridge(session: StubSession())
        let view = bridge.makeOrReuseView(font: .monospacedSystemFont(ofSize: 12, weight: .regular), scrollback: 7500)
        XCTAssertEqual(view.getTerminal().options.scrollback, 7500)
        // A resize used to be able to discard it (ADR-023 caveat) — no longer.
        bridge.sizeChanged(source: view, newCols: 120, newRows: 40)
        XCTAssertEqual(view.getTerminal().options.scrollback, 7500)
        // Live change to a new value.
        bridge.applyScrollback(2000, to: view)
        XCTAssertEqual(view.getTerminal().options.scrollback, 2000)
    }

    func testFeedReachesTerminalViewWhenNoSinkInstalled() async throws {
        // One real end-to-end feed: the emulator's buffer shows the text.
        let session = StubSession()
        let bridge = TerminalSessionBridge(session: session)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        bridge.attach(to: view)

        session.continuation.yield(Data("ferry-test".utf8))

        try await waitUntil("the emulator to show the fed text") {
            let terminal = view.getTerminal()
            guard let line = terminal.getLine(row: 0) else { return false }
            let text = (0..<terminal.cols).map { String(line[$0].getCharacter()) }.joined()
            return text.contains("ferry-test")
        }
    }
}
