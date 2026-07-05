import Foundation
import Network
import os

/// TCP reachability check behind the connection sheet's "Test Connection"
/// button (M4). From M6 this is superseded by a full protocol handshake for
/// SFTP; it remains the fallback for protocols not yet implemented.
public enum ReachabilityProbe {
    public struct Success: Sendable {
        /// Seconds until the TCP connection became ready.
        public let duration: TimeInterval
    }

    public enum ProbeError: Error, Sendable {
        case invalidPort(Int)
        case unreachable(reason: String)
        case timedOut(after: TimeInterval)
    }

    /// Opens a TCP connection to host:port and reports how long it took.
    /// Never throws before `timeout` elapses unless the OS reports failure.
    public static func tcpReachable(host: String, port: Int,
                                    timeout: TimeInterval = 5) async throws -> Success {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            throw ProbeError.invalidPort(port)
        }

        let start = ContinuousClock.now
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        defer { connection.cancel() }

        return try await withThrowingTaskGroup(of: Success.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    // stateUpdateHandler can fire multiple times; resume once.
                    let resumed = OSAllocatedUnfairLock(initialState: false)
                    connection.stateUpdateHandler = { state in
                        let claim: () -> Bool = {
                            resumed.withLock { done in
                                if done { return false }
                                done = true
                                return true
                            }
                        }
                        switch state {
                        case .ready:
                            guard claim() else { return }
                            let elapsed = (ContinuousClock.now - start).seconds
                            continuation.resume(returning: Success(duration: elapsed))
                        case .failed(let error):
                            guard claim() else { return }
                            continuation.resume(throwing: ProbeError.unreachable(reason: error.localizedDescription))
                        case .waiting(let error):
                            // "waiting" retries forever (e.g. host down); treat as failure.
                            guard claim() else { return }
                            continuation.resume(throwing: ProbeError.unreachable(reason: error.localizedDescription))
                        default:
                            break
                        }
                    }
                    connection.start(queue: .global(qos: .userInitiated))
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ProbeError.timedOut(after: timeout)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ProbeError.timedOut(after: timeout)
            }
            return first
        }
    }
}

private extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
