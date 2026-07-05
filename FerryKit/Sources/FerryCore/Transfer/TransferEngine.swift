import Foundation

/// One file copy between two FileSystemSources (local↔remote today,
/// remote↔remote later — the engine doesn't care).
public struct TransferRequest: Sendable, Identifiable {
    public enum Direction: String, Sendable {
        case download, upload
    }

    public let id: UUID
    public let direction: Direction
    public let source: any FileSystemSource
    public let sourcePath: String
    public let destination: any FileSystemSource
    public let destinationPath: String
    /// File name shown in the queue.
    public let displayName: String

    public init(id: UUID = UUID(),
                direction: Direction,
                source: any FileSystemSource, sourcePath: String,
                destination: any FileSystemSource, destinationPath: String,
                displayName: String) {
        self.id = id
        self.direction = direction
        self.source = source
        self.sourcePath = sourcePath
        self.destination = destination
        self.destinationPath = destinationPath
        self.displayName = displayName
    }
}

/// Point-in-time state of one queue item, streamed to observers.
public struct TransferSnapshot: Sendable, Identifiable {
    public enum Phase: Sendable, Equatable {
        case queued
        case running
        case completed
        case failed(String)
        case cancelled

        public var isFinished: Bool {
            switch self {
            case .completed, .failed, .cancelled: true
            case .queued, .running: false
            }
        }
    }

    public let id: UUID
    public let displayName: String
    public let direction: TransferRequest.Direction
    public let sourcePath: String
    public let destinationPath: String
    public let phase: Phase
    public let bytesTransferred: Int64
    public let totalBytes: Int64?
}

/// FIFO transfer queue with a concurrency cap (DOMAIN.md → Transfers:
/// default 3 concurrent per connection). Emits TransferSnapshots via
/// `events()`; new subscribers first receive a replay of current state.
/// M8 scope: single files, offset 0. Resume (`.ferrypart`) arrives in M9.
public actor TransferEngine {
    private let maxConcurrent: Int

    private var pending: [TransferRequest] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var snapshots: [UUID: TransferSnapshot] = [:]
    private var order: [UUID] = []
    private var subscribers: [UUID: AsyncStream<TransferSnapshot>.Continuation] = [:]

    public init(maxConcurrent: Int = 3) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Snapshot stream. Replays all known items on subscription, then live
    /// updates. Multiple subscribers supported.
    public func events() -> AsyncStream<TransferSnapshot> {
        AsyncStream { continuation in
            let token = UUID()
            subscribers[token] = continuation
            continuation.onTermination = { _ in
                Task { await self.dropSubscriber(token) }
            }
            for id in order {
                if let snapshot = snapshots[id] { continuation.yield(snapshot) }
            }
        }
    }

    public func enqueue(_ request: TransferRequest) {
        let snapshot = TransferSnapshot(id: request.id,
                                        displayName: request.displayName,
                                        direction: request.direction,
                                        sourcePath: request.sourcePath,
                                        destinationPath: request.destinationPath,
                                        phase: .queued,
                                        bytesTransferred: 0,
                                        totalBytes: nil)
        order.append(request.id)
        publish(snapshot)
        pending.append(request)
        pump()
    }

    /// Cancels a queued or running item; finished items are unaffected.
    /// For running items the cancelled state is published immediately and the
    /// slot freed — deterministic even when a backend await is not
    /// cancellation-aware (the cancellation handler in `perform` closes the
    /// write handle to actually stop the I/O; see ADR-013).
    public func cancel(id: UUID) {
        if let task = activeTasks[id] {
            update(id) { $0.with(phase: .cancelled) }
            task.cancel()
            finish(id)
        } else if let index = pending.firstIndex(where: { $0.id == id }) {
            let request = pending.remove(at: index)
            update(request.id) { $0.with(phase: .cancelled) }
        }
    }

    /// Drops finished items from the replayed state (UI "Clear").
    public func clearFinished() {
        let finished = order.filter { snapshots[$0]?.phase.isFinished == true }
        for id in finished {
            snapshots.removeValue(forKey: id)
        }
        order.removeAll { snapshots[$0] == nil }
    }

    // MARK: Scheduling

    private func pump() {
        while activeTasks.count < maxConcurrent, !pending.isEmpty {
            let request = pending.removeFirst()
            activeTasks[request.id] = Task { await self.perform(request) }
        }
    }

    private func finish(_ id: UUID) {
        activeTasks.removeValue(forKey: id)
        pump()
    }

    private func perform(_ request: TransferRequest) async {
        let total = (try? await request.source.stat(path: request.sourcePath))?.size
        update(request.id) { $0.with(phase: .running, totalBytes: total) }

        do {
            let stream = try await request.source.openRead(at: request.sourcePath, offset: 0)
            let handle = try await request.destination.openWrite(at: request.destinationPath, offset: 0)
            do {
                // The onCancel handler force-closes the write handle so that
                // backends whose awaits are not cancellation-aware (e.g. a
                // pending SFTP write) resume with an error instead of hanging
                // the task forever (ADR-013).
                try await withTaskCancellationHandler {
                    var transferred: Int64 = 0
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        try await handle.write(chunk)
                        transferred += Int64(chunk.count)
                        let progress = transferred
                        update(request.id) { $0.with(phase: .running, bytesTransferred: progress) }
                    }
                    try Task.checkCancellation()
                    try await handle.close()
                } onCancel: {
                    Task { try? await handle.close() }
                }
                update(request.id) { $0.with(phase: .completed) }
            } catch {
                try? await handle.close()
                throw error
            }
        } catch is CancellationError {
            update(request.id) { $0.with(phase: .cancelled) }
        } catch {
            let message = (error as? FileSystemSourceError).map(String.init(describing:))
                ?? error.localizedDescription
            update(request.id) { $0.with(phase: .failed(message)) }
        }
        finish(request.id)
    }

    // MARK: State publication

    private func update(_ id: UUID, _ change: (TransferSnapshot) -> TransferSnapshot) {
        // Finished states are terminal: late updates from a cancelled task's
        // zombie awaits must not resurrect an item.
        guard let current = snapshots[id], !current.phase.isFinished else { return }
        publish(change(current))
    }

    private func publish(_ snapshot: TransferSnapshot) {
        snapshots[snapshot.id] = snapshot
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }

    private func dropSubscriber(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }
}

private extension TransferSnapshot {
    func with(phase: Phase, bytesTransferred: Int64? = nil, totalBytes: Int64?? = nil) -> TransferSnapshot {
        TransferSnapshot(id: id,
                         displayName: displayName,
                         direction: direction,
                         sourcePath: sourcePath,
                         destinationPath: destinationPath,
                         phase: phase,
                         bytesTransferred: bytesTransferred ?? self.bytesTransferred,
                         totalBytes: totalBytes ?? self.totalBytes)
    }
}
