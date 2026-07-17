import XCTest
@testable import FerryCore

/// Deterministic fake transport for supervisor tests.
final class FakeConnection: SupervisedConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var pingShouldFail = false
    private var reestablishFailuresRemaining = 0
    private(set) var pingCount = 0
    private(set) var reestablishCount = 0

    func setPingShouldFail(_ fail: Bool) {
        lock.lock(); defer { lock.unlock() }
        pingShouldFail = fail
    }

    func setReestablishFailures(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        reestablishFailuresRemaining = count
    }

    // NSLock scoping in sync helpers — locks are not await-safe.
    private func recordPing() -> Bool {
        lock.lock(); defer { lock.unlock() }
        pingCount += 1
        return pingShouldFail
    }

    private func recordReestablish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        reestablishCount += 1
        if reestablishFailuresRemaining > 0 {
            reestablishFailuresRemaining -= 1
            return false
        }
        pingShouldFail = false // a rebuilt transport pings fine again
        return true
    }

    func ping() async throws {
        if recordPing() { throw FileSystemSourceError.io("dead link") }
    }

    func reestablish() async throws {
        if !recordReestablish() { throw FileSystemSourceError.io("still down") }
    }

    private(set) var disconnectCount = 0
    private func recordDisconnect() {
        lock.lock(); defer { lock.unlock() }
        disconnectCount += 1
    }
    func disconnect() async { recordDisconnect() }
}

final class ConnectionSupervisorTests: XCTestCase {
    private func makeSupervisor(_ connection: FakeConnection,
                                maxAttempts: Int = 3) -> ConnectionSupervisor {
        ConnectionSupervisor(connection: connection,
                             pingInterval: .milliseconds(40),
                             maxAttempts: maxAttempts,
                             backoff: .milliseconds(10))
    }

    /// Collects states from an already-open stream until `target` or timeout.
    /// Subscribe BEFORE triggering the failure — otherwise a fast reconnect
    /// cycle can finish before the subscription attaches and the transient
    /// states are missed. `armedBy` delays target matching until it returned
    /// true once (used to skip the replayed initial `.connected`).
    private func collect(_ stream: AsyncStream<ConnectionSupervisor.State>,
                         until target: ConnectionSupervisor.State,
                         timeout: TimeInterval = 5,
                         armedBy: ((ConnectionSupervisor.State) -> Bool)? = nil)
        async -> [ConnectionSupervisor.State] {
        var seen: [ConnectionSupervisor.State] = []
        var armed = armedBy == nil
        let deadline = Date().addingTimeInterval(timeout)
        for await state in stream {
            seen.append(state)
            if !armed, let armedBy, armedBy(state) { armed = true }
            if (armed && state == target) || Date() > deadline { break }
        }
        return seen
    }

    func testKeepAlivePingsWhileHealthy() async throws {
        let connection = FakeConnection()
        let supervisor = makeSupervisor(connection)
        await supervisor.start()
        try await Task.sleep(for: .milliseconds(200))
        await supervisor.stop()

        XCTAssertGreaterThanOrEqual(connection.pingCount, 2,
                                    "keep-alive must ping repeatedly")
        XCTAssertEqual(connection.reestablishCount, 0)
        let state = await supervisor.state
        XCTAssertEqual(state, .connected)
    }

    func testFailedPingTriggersReconnectAndRecovers() async throws {
        let connection = FakeConnection()
        connection.setPingShouldFail(true)
        let supervisor = makeSupervisor(connection)
        let stream = await supervisor.events()
        await supervisor.start()

        let states = await collect(stream, until: .connected) { $0 != .connected }
        await supervisor.stop()

        XCTAssertTrue(states.contains(.reconnecting(attempt: 1)),
                      "must pass through reconnecting, got \(states)")
        XCTAssertEqual(states.last, .connected)
        XCTAssertGreaterThanOrEqual(connection.reestablishCount, 1)
    }

    func testBackoffWalksAttemptsThenGivesUp() async throws {
        let connection = FakeConnection()
        connection.setPingShouldFail(true)
        connection.setReestablishFailures(99)
        let supervisor = makeSupervisor(connection, maxAttempts: 3)
        let stream = await supervisor.events()
        await supervisor.start()

        let states = await collect(stream, until: .lost)

        XCTAssertEqual(states.filter {
            if case .reconnecting = $0 { return true } else { return false }
        }, [.reconnecting(attempt: 1), .reconnecting(attempt: 2), .reconnecting(attempt: 3)])
        XCTAssertEqual(states.last, .lost)
        XCTAssertEqual(connection.reestablishCount, 3)

        // Manual retry after the link was declared lost.
        connection.setReestablishFailures(0)
        let recoveryStream = await supervisor.events()
        await supervisor.reconnectNow()
        let recovery = await collect(recoveryStream, until: .connected)
        XCTAssertEqual(recovery.last, .connected)
        await supervisor.stop()
    }

    func testNoteFailureTriggersImmediateReconnect() async throws {
        let connection = FakeConnection()
        // Huge ping interval: only noteFailure can trigger the reconnect.
        let supervisor = ConnectionSupervisor(connection: connection,
                                              pingInterval: .seconds(3600),
                                              maxAttempts: 3,
                                              backoff: .milliseconds(10))
        let stream = await supervisor.events()
        await supervisor.start()
        await supervisor.noteFailure()

        let states = await collect(stream, until: .connected, timeout: 2) { $0 != .connected }
        await supervisor.stop()

        XCTAssertTrue(states.contains(.reconnecting(attempt: 1)))
        XCTAssertEqual(states.last, .connected)
        XCTAssertEqual(connection.reestablishCount, 1)
    }

    func testNoteFailureIsIgnoredWhileAlreadyReconnecting() async throws {
        let connection = FakeConnection()
        connection.setReestablishFailures(1)
        let supervisor = ConnectionSupervisor(connection: connection,
                                              pingInterval: .seconds(3600),
                                              maxAttempts: 3,
                                              backoff: .milliseconds(50))
        let stream = await supervisor.events()
        await supervisor.start()
        await supervisor.noteFailure()
        await supervisor.noteFailure() // must not start a second cycle
        await supervisor.noteFailure()

        let states = await collect(stream, until: .connected, timeout: 2) { $0 != .connected }
        await supervisor.stop()

        XCTAssertEqual(states.last, .connected)
        XCTAssertEqual(connection.reestablishCount, 2,
                       "one cycle: attempt 1 fails, attempt 2 succeeds — no parallel cycles")
    }
}
