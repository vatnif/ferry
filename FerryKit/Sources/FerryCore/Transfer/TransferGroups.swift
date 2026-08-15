import Foundation

/// Aggregate progress of one transfer group (all snapshots the tracker has
/// seen for the group's members).
public struct TransferGroupProgress: Sendable, Equatable {
    public var bytesTransferred: Int64
    /// nil until enumeration closes — a folder's total is unknown while any
    /// directory member is still expanding, and an honest indeterminate beats
    /// a number that jumps.
    public var totalBytes: Int64?
    public var itemsFinished: Int
    public var itemsKnown: Int

    public init(bytesTransferred: Int64, totalBytes: Int64?,
                itemsFinished: Int, itemsKnown: Int) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.itemsFinished = itemsFinished
        self.itemsKnown = itemsKnown
    }
}

/// How a group concluded. Precedence when members disagree: any failure
/// outranks cancellation outranks completion.
public enum TransferGroupOutcome: Sendable, Equatable {
    case completed
    case failed(String)
    case cancelled
}

public enum TransferGroupEvent: Sendable {
    case progress(TransferGroupProgress)
    /// A member is paused: the group cannot finish until it resumes or is
    /// cancelled. Stream stays open.
    case stalled
    /// Terminal — the stream finishes right after this.
    case finished(TransferGroupOutcome)
}

public struct TransferGroupHandle: Sendable {
    public let groupID: UUID
    public let events: AsyncStream<TransferGroupEvent>
}

/// Turns per-item TransferSnapshots into one truthful per-group completion
/// signal. The engine marks a directory `.completed` as soon as its children
/// are *enqueued*, so awaiting the root request alone would report "done" far
/// too early (the Finder drag-out must only signal its promise after every
/// byte lands). The stopping rule "every known member is finished" is sound
/// because children publish `.queued` synchronously inside the engine actor
/// before their parent's terminal event.
public actor TransferGroupTracker {
    private let engine: TransferEngine
    /// group → member id → latest snapshot. Retained independently of the
    /// engine, so `clearFinished()` mid-group cannot un-know a member.
    private var members: [UUID: [UUID: TransferSnapshot]] = [:]
    /// The seeded root id is what makes "all known members finished" safe
    /// rather than vacuously true for a group whose root never enqueued.
    private var roots: [UUID: UUID] = [:]
    private var continuations: [UUID: AsyncStream<TransferGroupEvent>.Continuation] = [:]
    /// Concluded groups are frozen: a `resume` of a failed directory
    /// re-enqueues members, and those must not produce a second `.finished`.
    private var concluded: Set<UUID> = []
    /// Groups being cancelled: members observed after `cancelGroup` (the
    /// enqueue/consume race) are cancelled as they appear.
    private var cancelling: Set<UUID> = []
    // nonisolated(unsafe): written once in init, read in deinit — no races.
    nonisolated(unsafe) private var consumeTask: Task<Void, Never>?

    /// Constructed WITH the engine so it can never miss a member: a tracker
    /// that subscribed late (after `clearFinished()`) would see an empty group
    /// and vacuously call it done.
    public init(engine: TransferEngine) {
        self.engine = engine
        consumeTask = Task { [weak self, engine] in
            for await snapshot in await engine.events() {
                guard let self else { break }
                await self.observe(snapshot)
            }
        }
    }

    deinit {
        consumeTask?.cancel()
    }

    /// Call BEFORE enqueueing the root — the group is only evaluated once the
    /// seeded root's own snapshot has been seen.
    public func open(group: UUID, root: UUID) -> TransferGroupHandle {
        roots[group] = root
        if members[group] == nil { members[group] = [:] }
        let events = AsyncStream<TransferGroupEvent> { continuation in
            continuations[group] = continuation
            continuation.onTermination = { _ in
                Task { await self.dropContinuation(group) }
            }
        }
        return TransferGroupHandle(groupID: group, events: events)
    }

    /// Cancels every known member (and the root, which may not have been
    /// observed yet); members that surface later are cancelled on sight.
    public func cancelGroup(_ group: UUID) async {
        guard let root = roots[group], !concluded.contains(group) else { return }
        cancelling.insert(group)
        var ids = Set(members[group, default: [:]].keys)
        ids.insert(root)
        for id in ids {
            await engine.cancel(id: id)
        }
    }

    // MARK: Snapshot consumption

    private func observe(_ snapshot: TransferSnapshot) {
        guard let group = snapshot.groupID,
              roots[group] != nil,
              !concluded.contains(group) else { return }
        members[group, default: [:]][snapshot.id] = snapshot
        if cancelling.contains(group), !snapshot.phase.isFinished {
            let id = snapshot.id
            Task { await engine.cancel(id: id) }
        }
        evaluate(group)
    }

    private func evaluate(_ group: UUID) {
        guard let root = roots[group], let snapshots = members[group] else { return }
        let continuation = continuations[group]
        if snapshots[root] != nil, snapshots.values.allSatisfy({ $0.phase.isFinished }) {
            continuation?.yield(.finished(Self.outcome(of: snapshots.values)))
            continuation?.finish()
            conclude(group)
            return
        }
        // A paused member is not finished, so the completion check above
        // already cannot fire — but without an explicit signal the consumer
        // would wait forever. `.stalled` marks the transition.
        if snapshots.values.contains(where: { $0.phase == .paused }) {
            continuation?.yield(.stalled)
            return
        }
        continuation?.yield(.progress(Self.progress(of: snapshots.values)))
    }

    private func conclude(_ group: UUID) {
        concluded.insert(group)
        continuations.removeValue(forKey: group)
        cancelling.remove(group)
        members.removeValue(forKey: group)
        roots.removeValue(forKey: group)
    }

    private func dropContinuation(_ group: UUID) {
        continuations.removeValue(forKey: group)
    }

    // MARK: Aggregation

    private static func outcome(
        of snapshots: some Collection<TransferSnapshot>) -> TransferGroupOutcome {
        for snapshot in snapshots {
            if case .failed(let message) = snapshot.phase { return .failed(message) }
        }
        if snapshots.contains(where: { $0.phase == .cancelled }) { return .cancelled }
        return .completed
    }

    private static func progress(
        of snapshots: some Collection<TransferSnapshot>) -> TransferGroupProgress {
        let bytes = snapshots.reduce(Int64(0)) { $0 + $1.bytesTransferred }
        let finished = snapshots.count { $0.phase.isFinished }
        // The total is only honest once no directory can still add members
        // and every file has reported its size.
        let enumerationClosed = snapshots
            .filter { $0.kind == .directory }
            .allSatisfy { $0.phase.isFinished }
        let fileTotals = snapshots.filter { $0.kind == .file }.map(\.totalBytes)
        let total: Int64? = (enumerationClosed && !fileTotals.contains(nil))
            ? fileTotals.compactMap { $0 }.reduce(0, +)
            : nil
        return TransferGroupProgress(bytesTransferred: bytes, totalBytes: total,
                                     itemsFinished: finished, itemsKnown: snapshots.count)
    }
}
