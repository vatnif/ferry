import Foundation

/// One item to copy between two FileSystemSources (local↔remote today,
/// remote↔remote later — the engine doesn't care). Directories enumerate
/// lazily when they reach the front of the queue (DOMAIN.md → Transfers).
public struct TransferRequest: Sendable, Identifiable {
    public enum Direction: String, Sendable {
        case download, upload
    }

    public enum Kind: String, Sendable {
        case file, directory
    }

    /// Interrupted-transfer policy for this item (DOMAIN.md default:
    /// resume automatically).
    public enum Mode: String, Sendable {
        /// Resume from existing partial data when it is valid: downloads from
        /// `<name>.ferrypart`, uploads from a smaller existing remote file.
        case automatic
        /// Start over at byte 0 (e.g. the user chose Replace on a conflict).
        case restart
    }

    public let id: UUID
    public let direction: Direction
    public let kind: Kind
    public var mode: Mode
    /// Items enqueued as one user action (e.g. a Finder drag-out) share a
    /// group; a directory's children inherit it. TransferGroupTracker turns
    /// the members' snapshots into one aggregate completion signal.
    public let groupID: UUID?
    public let source: any FileSystemSource
    public let sourcePath: String
    public let destination: any FileSystemSource
    public let destinationPath: String
    /// File name shown in the queue.
    public let displayName: String

    public init(id: UUID = UUID(),
                direction: Direction,
                kind: Kind = .file,
                mode: Mode = .automatic,
                groupID: UUID? = nil,
                source: any FileSystemSource, sourcePath: String,
                destination: any FileSystemSource, destinationPath: String,
                displayName: String) {
        self.id = id
        self.direction = direction
        self.kind = kind
        self.mode = mode
        self.groupID = groupID
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
        /// Stopped by the user with partial data kept; `resume(id:)` continues.
        case paused
        case completed
        case failed(String)
        case cancelled

        public var isFinished: Bool {
            switch self {
            case .completed, .failed, .cancelled: true
            case .queued, .running, .paused: false
            }
        }
    }

    public let id: UUID
    public let displayName: String
    public let direction: TransferRequest.Direction
    public let kind: TransferRequest.Kind
    public let groupID: UUID?
    public let sourcePath: String
    public let destinationPath: String
    public let phase: Phase
    public let bytesTransferred: Int64
    public let totalBytes: Int64?
    /// 1-based; > 1 while the retry policy is re-running a failed item.
    public let attempt: Int
    /// Non-nil when the current run continued existing partial data
    /// (queue badge RESUMED).
    public let resumedFromOffset: Int64?
}

/// FIFO transfer queue with a concurrency cap (DOMAIN.md → Transfers:
/// default 3 concurrent per connection). Emits TransferSnapshots via
/// `events()`; new subscribers first receive a replay of current state.
///
/// M9 additions:
/// - Downloads stage into `<destination>.ferrypart` and atomically rename on
///   completion; a valid partial resumes from its byte count. Partials older
///   than `partialMaxAge` (30 days) are discarded on encounter (the GC rule).
/// - Uploads resume from the remote size when it is smaller than the source.
/// - Transient failures (`.io` / unknown) retry up to `maxAttempts` with
///   `retryDelay` spacing, resuming partial data; deterministic errors
///   (notFound, permissionDenied, …) fail immediately.
/// - `pause(id:)` / `resume(id:)`; paused items keep their partial data.
/// - Directory items enumerate lazily when they start: create the
///   destination directory, then enqueue one item per child.
public actor TransferEngine {
    /// Staging suffix for downloads (DOMAIN.md → Resume).
    public static let partialSuffix = ".ferrypart"

    private let maxConcurrent: Int
    private let maxAttempts: Int
    private let retryDelay: Duration
    private let partialMaxAge: TimeInterval

    private var requests: [UUID: TransferRequest] = [:]
    private var pending: [TransferRequest] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var snapshots: [UUID: TransferSnapshot] = [:]
    private var order: [UUID] = []
    private var subscribers: [UUID: AsyncStream<TransferSnapshot>.Continuation] = [:]

    public init(maxConcurrent: Int = 3,
                maxAttempts: Int = 3,
                retryDelay: Duration = .seconds(5),
                partialMaxAge: TimeInterval = 30 * 24 * 3600) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxAttempts = max(1, maxAttempts)
        self.retryDelay = retryDelay
        self.partialMaxAge = partialMaxAge
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
        requests[request.id] = request
        order.append(request.id)
        publish(TransferSnapshot(id: request.id,
                                 displayName: request.displayName,
                                 direction: request.direction,
                                 kind: request.kind,
                                 groupID: request.groupID,
                                 sourcePath: request.sourcePath,
                                 destinationPath: request.destinationPath,
                                 phase: .queued,
                                 bytesTransferred: 0,
                                 totalBytes: nil,
                                 attempt: 1,
                                 resumedFromOffset: nil))
        pending.append(request)
        pump()
    }

    /// Cancels a queued, running, or paused item; finished items are
    /// unaffected. For running items the cancelled state is published and the
    /// slot freed immediately — deterministic even when a backend await is
    /// not cancellation-aware (the cancellation handler in `performFile`
    /// closes the write handle to actually stop the I/O; see ADR-013).
    /// Partial data stays on disk for a later automatic resume (GC'd after
    /// `partialMaxAge`).
    public func cancel(id: UUID) {
        if let task = activeTasks[id] {
            update(id) { $0.with(phase: .cancelled) }
            task.cancel()
            finish(id)
        } else if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index)
            update(id) { $0.with(phase: .cancelled) }
        } else if let current = snapshots[id], current.phase == .paused {
            publish(current.with(phase: .cancelled))
        }
    }

    /// Stops a queued or running item, keeping its partial data; the snapshot
    /// becomes `.paused` and `resume(id:)` continues it. Uses the same
    /// publish-first-then-cancel discipline as `cancel` (ADR-013): the paused
    /// state is terminal for the interrupted task, so its zombie awaits
    /// cannot resurrect the item.
    public func pause(id: UUID) {
        if let task = activeTasks[id] {
            update(id) { $0.with(phase: .paused) }
            task.cancel()
            finish(id)
        } else if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index)
            update(id) { $0.with(phase: .paused) }
        }
    }

    /// Re-queues a paused or failed item; the new run resumes partial data
    /// (mode becomes `.automatic` — an interrupted Replace continues its own
    /// partial rather than starting over again).
    public func resume(id: UUID) {
        guard var request = requests[id],
              let current = snapshots[id],
              current.phase == .paused || isFailed(current.phase),
              activeTasks[id] == nil,
              !pending.contains(where: { $0.id == id }) else { return }
        request.mode = .automatic
        requests[id] = request
        publish(current.with(phase: .queued, attempt: 1, resumedFromOffset: .some(nil)))
        pending.append(request)
        pump()
    }

    /// Drops finished items from the replayed state (UI "Clear").
    public func clearFinished() {
        let finished = order.filter { snapshots[$0]?.phase.isFinished == true }
        for id in finished {
            snapshots.removeValue(forKey: id)
            requests.removeValue(forKey: id)
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

    private func isFailed(_ phase: TransferSnapshot.Phase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: Transfer execution

    private func perform(_ request: TransferRequest) async {
        var attempt = 1
        while true {
            do {
                switch request.kind {
                case .file: try await performFile(request, attempt: attempt)
                case .directory: try await performDirectory(request, attempt: attempt)
                }
                update(request.id) { $0.with(phase: .completed) }
            } catch is CancellationError {
                // cancel()/pause() already published the terminal state.
            } catch {
                let message = Self.describe(error)
                if attempt < maxAttempts, Self.isTransient(error) {
                    attempt += 1
                    let next = attempt
                    update(request.id) { $0.with(phase: .queued, attempt: next) }
                    do {
                        try await Task.sleep(for: retryDelay)
                        continue
                    } catch {
                        // Cancelled/paused during backoff — state already published.
                    }
                } else {
                    update(request.id) { $0.with(phase: .failed(message)) }
                }
            }
            break
        }
        finish(request.id)
    }

    /// Deterministic errors (missing file, permissions, bad offset, …) fail
    /// immediately; only I/O-level and unknown errors are worth retrying
    /// (DOMAIN.md: failed items retry 3× with 5 s spacing).
    private static func isTransient(_ error: Error) -> Bool {
        guard let sourceError = error as? FileSystemSourceError else { return true }
        if case .io = sourceError { return true }
        return false
    }

    private func performDirectory(_ request: TransferRequest, attempt: Int) async throws {
        update(request.id) { $0.with(phase: .running, attempt: attempt) }
        let existing = try? await request.destination.stat(path: request.destinationPath)
        if existing?.isDirectory != true {
            try await request.destination.createDirectory(at: request.destinationPath)
        }
        let children = try await request.source.list(directory: request.sourcePath, includeHidden: true)
        try Task.checkCancellation()
        // Files before subdirectories, names stable — the queue reads naturally.
        let sorted = children.sorted {
            if $0.isDirectory != $1.isDirectory { return !$0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        for child in sorted {
            enqueue(TransferRequest(direction: request.direction,
                                    kind: child.isDirectory ? .directory : .file,
                                    mode: request.mode,
                                    groupID: request.groupID,
                                    source: request.source, sourcePath: child.path,
                                    destination: request.destination,
                                    destinationPath: Self.join(request.destinationPath, child.name),
                                    displayName: child.name))
        }
    }

    private struct WritePlan {
        var writePath: String
        var offset: Int64
        /// True when writing to a `.ferrypart` that must be renamed into
        /// place on completion (downloads).
        var staged: Bool
    }

    private func plan(for request: TransferRequest, totalBytes: Int64?) async -> WritePlan {
        switch request.direction {
        case .download:
            let partial = request.destinationPath + Self.partialSuffix
            guard request.mode == .automatic,
                  let stat = try? await request.destination.stat(path: partial),
                  !stat.isDirectory,
                  let size = stat.size, size > 0,
                  isFresh(stat.modifiedAt),
                  let totalBytes, size <= totalBytes else {
                return WritePlan(writePath: partial, offset: 0, staged: true)
            }
            return WritePlan(writePath: partial, offset: size, staged: true)
        case .upload:
            // Resume heuristic (DOMAIN.md): an existing smaller remote file is
            // treated as this transfer's own interrupted partial.
            guard request.mode == .automatic,
                  let totalBytes,
                  let stat = try? await request.destination.stat(path: request.destinationPath),
                  !stat.isDirectory,
                  let size = stat.size, size > 0, size <= totalBytes else {
                return WritePlan(writePath: request.destinationPath, offset: 0, staged: false)
            }
            return WritePlan(writePath: request.destinationPath, offset: size, staged: false)
        }
    }

    /// Partials older than `partialMaxAge` are discarded — encountering one
    /// is when the 30-day `.ferrypart` GC actually runs (openWrite at offset
    /// 0 truncates it away).
    private func isFresh(_ modifiedAt: Date?) -> Bool {
        guard let modifiedAt else { return true }
        return Date().timeIntervalSince(modifiedAt) <= partialMaxAge
    }

    private func performFile(_ request: TransferRequest, attempt: Int) async throws {
        let total = (try? await request.source.stat(path: request.sourcePath))?.size
        let plan = await plan(for: request, totalBytes: total)
        let resumedFrom: Int64? = plan.offset > 0 ? plan.offset : nil
        update(request.id) {
            $0.with(phase: .running, attempt: attempt, bytesTransferred: plan.offset,
                    totalBytes: total, resumedFromOffset: .some(resumedFrom))
        }

        if let total, plan.offset == total {
            // Nothing left to copy (e.g. the partial already holds every byte).
            if plan.staged { try await finalize(request, partialPath: plan.writePath) }
            return
        }

        let stream = try await request.source.openRead(at: request.sourcePath, offset: plan.offset)
        let handle = try await request.destination.openWrite(at: plan.writePath, offset: plan.offset)
        do {
            // The onCancel handler force-closes the write handle so that
            // backends whose awaits are not cancellation-aware (e.g. a
            // pending SFTP write) resume with an error instead of hanging
            // the task forever (ADR-013).
            try await withTaskCancellationHandler {
                var transferred = plan.offset
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
        } catch {
            try? await handle.close()
            throw error
        }
        if plan.staged { try await finalize(request, partialPath: plan.writePath) }
    }

    /// Moves the completed `.ferrypart` into place. `rename` refuses to
    /// overwrite (M5 contract), so an existing destination — the user already
    /// confirmed replacement at staging time — is deleted first.
    private func finalize(_ request: TransferRequest, partialPath: String) async throws {
        if (try? await request.destination.stat(path: request.destinationPath)) != nil {
            try await request.destination.delete(at: request.destinationPath)
        }
        try await request.destination.rename(from: partialPath, to: request.destinationPath)
    }

    private static func describe(_ error: Error) -> String {
        (error as? FileSystemSourceError).map(String.init(describing:))
            ?? error.localizedDescription
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    // MARK: State publication

    private func update(_ id: UUID, _ change: (TransferSnapshot) -> TransferSnapshot) {
        // Finished states are terminal, and paused items are frozen until
        // resume(id:): late updates from an interrupted task's zombie awaits
        // must not resurrect or advance them. Pause→queued and paused→
        // cancelled transitions go through publish() directly.
        guard let current = snapshots[id],
              !current.phase.isFinished,
              current.phase != .paused else { return }
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
    func with(phase: Phase,
              attempt: Int? = nil,
              bytesTransferred: Int64? = nil,
              totalBytes: Int64?? = nil,
              resumedFromOffset: Int64?? = nil) -> TransferSnapshot {
        TransferSnapshot(id: id,
                         displayName: displayName,
                         direction: direction,
                         kind: kind,
                         groupID: groupID,
                         sourcePath: sourcePath,
                         destinationPath: destinationPath,
                         phase: phase,
                         bytesTransferred: bytesTransferred ?? self.bytesTransferred,
                         totalBytes: totalBytes ?? self.totalBytes,
                         attempt: attempt ?? self.attempt,
                         resumedFromOffset: resumedFromOffset ?? self.resumedFromOffset)
    }
}
