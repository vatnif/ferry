import Foundation
import XCTest
@testable import FerryCore

/// Real PTY shells against the exec-capable OpenSSH server (:2223) — the
/// M15.5 embedded terminal's engine, end-to-end (ADR-023). Like the SCP suite,
/// everything here is macOS 15+ (Citadel's `withPTY` gate).
///
/// Every wait races a deadline — never bare event arrival (the ADR-014 lesson).
@available(macOS 15.0, *)
final class TerminalSessionIntegrationTests: XCTestCase {

    override func setUp() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.scpPort, serverName: "SSH/exec")
        try await TestServers.trustSSHExecHostKey()
    }

    // MARK: Helpers

    /// Accumulates a session's output for containment checks. Holds the
    /// stream's single consumer slot for the session's lifetime.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var task: Task<Void, Never>?

        init(_ session: TerminalSession) {
            task = Task { [weak self] in
                for await chunk in session.output {
                    guard let self else { return }
                    self.lock.withLock { self.buffer.append(chunk) }
                }
            }
        }

        var text: String { lock.withLock { String(decoding: buffer, as: UTF8.self) } }
        deinit { task?.cancel() }
    }

    private func makeSession(password: String = TestServers.password,
                             port: UInt16 = TestServers.scpPort) -> TerminalSession {
        TerminalSession(host: TestServers.host, port: Int(port),
                        username: TestServers.username,
                        credential: .password(password),
                        hostKeyStore: TestServers.sharedHostKeyStore)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20,
                           _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func waitForRunning(_ session: TerminalSession) async throws {
        try await waitUntil("the shell to reach .running") {
            await session.currentState == .running
        }
    }

    private func send(_ text: String, to session: TerminalSession) async {
        await session.send(Data(text.utf8))
    }

    // MARK: Tests

    func testShellCommandRoundTrip() async throws {
        let session = makeSession()
        let output = OutputCollector(session)
        await session.start(columns: 80, rows: 24)
        try await waitForRunning(session)

        // The PTY echoes the typed line, so assert on the *result* string,
        // which only exists after the shell evaluated the arithmetic.
        await send("echo hello-$((6*7))\n", to: session)
        try await waitUntil("the command result to come back") {
            output.text.contains("hello-42")
        }

        await session.terminate()
        let state = await session.currentState
        XCTAssertEqual(state, .ended(.exited))
    }

    func testResizePropagatesToTheRemotePTY() async throws {
        let session = makeSession()
        let output = OutputCollector(session)
        await session.start(columns: 80, rows: 24)
        try await waitForRunning(session)

        await session.resize(columns: 120, rows: 40)
        // window-change and the keystrokes are ordered on the same channel,
        // so stty reads the already-updated size.
        await send("stty size\n", to: session)
        try await waitUntil("stty to report the new size") {
            output.text.contains("40 120")
        }

        await session.terminate()
    }

    func testExitEndsTheSessionCleanly() async throws {
        let session = makeSession()
        _ = OutputCollector(session)
        await session.start(columns: 80, rows: 24)
        try await waitForRunning(session)

        await send("exit\n", to: session)
        try await waitUntil("the session to end") {
            if case .ended = await session.currentState { return true }
            return false
        }
        let state = await session.currentState
        XCTAssertEqual(state, .ended(.exited))
    }

    func testNonZeroExitCodeIsStillACleanExit() async throws {
        // Covers the SSHClient.CommandFailed → .exited classifier branch that
        // the unit suite can't construct (internal initializer).
        let session = makeSession()
        _ = OutputCollector(session)
        await session.start(columns: 80, rows: 24)
        try await waitForRunning(session)

        await send("exit 1\n", to: session)
        try await waitUntil("the session to end") {
            if case .ended = await session.currentState { return true }
            return false
        }
        let state = await session.currentState
        XCTAssertEqual(state, .ended(.exited),
                       "a non-zero shell exit code is a normal exit, not a failure")
    }

    func testWrongPasswordFailsWithTypedMessage() async throws {
        let session = makeSession(password: "definitely-wrong")
        await session.start(columns: 80, rows: 24)
        try await waitUntil("the connect to fail") {
            if case .ended(.failed) = await session.currentState { return true }
            return false
        }
        let state = await session.currentState
        XCTAssertEqual(state, .ended(.failed("Authentication failed.")))
    }

    func testUserTerminateWhileShellIsLive() async throws {
        let session = makeSession()
        _ = OutputCollector(session)
        await session.start(columns: 80, rows: 24)
        try await waitForRunning(session)

        // Simulates closing the panel mid-command; must end promptly and
        // read as a user close, not a failure (DESIGN.md screen 7).
        await send("sleep 300\n", to: session)
        let began = Date()
        await session.terminate()
        XCTAssertLessThan(Date().timeIntervalSince(began), 5,
                          "terminate is bounded even with a command running")
        let state = await session.currentState
        XCTAssertEqual(state, .ended(.exited))
    }

    func testRestartAfterExitStartsAFreshShell() async throws {
        // The ended-state banner's Restart Session button (screen 7).
        let session = makeSession()
        let output = OutputCollector(session)
        await session.start(columns: 80, rows: 24)
        try await waitForRunning(session)
        await send("exit\n", to: session)
        try await waitUntil("the first shell to end") {
            if case .ended = await session.currentState { return true }
            return false
        }

        await session.start(columns: 80, rows: 24)
        try await waitForRunning(session)
        await send("echo again-$((2+3))\n", to: session)
        try await waitUntil("the restarted shell to respond") {
            output.text.contains("again-5")
        }
        await session.terminate()
    }

    func testForcedCommandServerDoesNotHang() async throws {
        // :2222 (atmoz) forces internal-sftp: the shell request succeeds but
        // the forced command speaks binary SFTP, not a shell — same as
        // `ssh` against such a server. Pin the defined behavior: the session
        // must never hang; typed input makes the forced command exit, ending
        // the session (the UI then shows the ended banner).
        _ = try TestServers.requireGreeting(port: TestServers.sftpPort, serverName: "SFTP")
        let sftp = try await TestServers.connectSFTP()   // trusts :2222 in the shared store
        await sftp.disconnect()

        let session = makeSession(port: TestServers.sftpPort)
        _ = OutputCollector(session)
        await session.start(columns: 80, rows: 24)

        try await waitUntil("the forced-command session to run or end") {
            let state = await session.currentState
            if state == .running { return true }
            if case .ended = state { return true }
            return false
        }
        if await session.currentState == .running {
            await send("not-sftp-protocol\n", to: session)
            try await waitUntil("the forced command to give up") {
                if case .ended = await session.currentState { return true }
                return false
            }
        }
        await session.terminate()
    }
}
