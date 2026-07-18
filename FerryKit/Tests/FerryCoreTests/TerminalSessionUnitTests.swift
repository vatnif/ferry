import Citadel
import NIOCore
import NIOSSH
import XCTest
@testable import FerryCore

/// Unit vectors for the terminal's end-reason classifier and PTY request
/// construction (M15.5, ADR-023). The classifier is the piece `withPTY`'s
/// "Already closed" error masking makes safety-critical: the out-of-band
/// flags must outrank whatever the closure throws (the ADR-020 lesson).
@available(macOS 15.0, *)
final class TerminalSessionUnitTests: XCTestCase {

    // MARK: End-reason classification

    func testNilErrorIsCleanExit() {
        XCTAssertEqual(TerminalEndClassifier.endReason(thrown: nil,
                                                       userTerminated: false,
                                                       sessionDropped: false),
                       .exited)
    }

    func testUserTerminationOutranksAnyError() {
        struct Boom: Error {}
        XCTAssertEqual(TerminalEndClassifier.endReason(thrown: Boom(),
                                                       userTerminated: true,
                                                       sessionDropped: false),
                       .exited)
    }

    func testUserTerminationOutranksSessionDrop() {
        // Closing the terminal while the transport is dying is still a close.
        XCTAssertEqual(TerminalEndClassifier.endReason(thrown: nil,
                                                       userTerminated: true,
                                                       sessionDropped: true),
                       .exited)
    }

    func testSessionDropIsFailure() {
        XCTAssertEqual(TerminalEndClassifier.endReason(thrown: nil,
                                                       userTerminated: false,
                                                       sessionDropped: true),
                       .failed("The SSH session dropped."))
    }

    // Note: the `SSHClient.CommandFailed` → .exited vector (a non-zero shell
    // exit code) can't be unit-tested — Citadel keeps its initializer internal.
    // The integration suite covers it with a real `exit 1` against :2223.

    func testAlreadyClosedCleanupArtifactIsAnExit() {
        // withPTY's cleanup close() after the remote shell exited (ADR-020).
        XCTAssertEqual(TerminalEndClassifier.endReason(thrown: ChannelError.alreadyClosed,
                                                       userTerminated: false,
                                                       sessionDropped: false),
                       .exited)
        XCTAssertEqual(TerminalEndClassifier.endReason(thrown: ChannelError.ioOnClosedChannel,
                                                       userTerminated: false,
                                                       sessionDropped: false),
                       .exited)
    }

    func testCancellationIsAnExit() {
        XCTAssertEqual(TerminalEndClassifier.endReason(thrown: CancellationError(),
                                                       userTerminated: false,
                                                       sessionDropped: false),
                       .exited)
    }

    func testShellRefusalIsAClearFailure() {
        // ChannelFailureEvent → CitadelError.channelFailure: the server accepted
        // the connection but refused the shell (SFTP-only/ForceCommand server).
        let reason = TerminalEndClassifier.endReason(thrown: CitadelError.channelFailure,
                                                     userTerminated: false,
                                                     sessionDropped: false)
        guard case .failed(let message) = reason else {
            return XCTFail("expected .failed, got \(reason)")
        }
        XCTAssertTrue(message.contains("refused an interactive shell"), message)
    }

    func testConnectErrorsMapToUserPresentableMessages() {
        XCTAssertEqual(TerminalEndClassifier.endReason(thrown: RemoteSourceError.authenticationFailed,
                                                       userTerminated: false,
                                                       sessionDropped: false),
                       .failed("Authentication failed."))

        let connect = TerminalEndClassifier.endReason(
            thrown: RemoteSourceError.connectionFailed("host unreachable"),
            userTerminated: false, sessionDropped: false)
        guard case .failed(let message) = connect else {
            return XCTFail("expected .failed, got \(connect)")
        }
        XCTAssertTrue(message.contains("host unreachable"), message)
    }

    func testUnknownErrorFailsWithDescription() {
        struct Weird: Error {}
        let reason = TerminalEndClassifier.endReason(thrown: Weird(),
                                                     userTerminated: false,
                                                     sessionDropped: false)
        guard case .failed(let message) = reason else {
            return XCTFail("expected .failed, got \(reason)")
        }
        XCTAssertTrue(message.contains("Weird"), message)
    }

    // MARK: PTY request construction

    func testPTYRequestCarriesTermTypeAndDimensions() {
        let request = TerminalSession.ptyRequest(terminalType: "xterm-256color",
                                                 columns: 120, rows: 34)
        XCTAssertEqual(request.term, "xterm-256color")
        XCTAssertEqual(request.terminalCharacterWidth, 120)
        XCTAssertEqual(request.terminalRowHeight, 34)
        // Character dims rule; pixel dims deliberately zero.
        XCTAssertEqual(request.terminalPixelWidth, 0)
        XCTAssertEqual(request.terminalPixelHeight, 0)
        XCTAssertTrue(request.wantReply)
    }

    func testPTYRequestClampsDegenerateDimensions() {
        // A zero-sized view must never request a 0×0 PTY.
        let request = TerminalSession.ptyRequest(terminalType: "xterm-256color",
                                                 columns: 0, rows: -3)
        XCTAssertGreaterThanOrEqual(request.terminalCharacterWidth, 2)
        XCTAssertGreaterThanOrEqual(request.terminalRowHeight, 2)
    }
}
