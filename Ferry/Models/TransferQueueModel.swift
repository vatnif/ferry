import SwiftUI
import FerryCore

/// Main-actor projection of TransferEngine state for the queue dock:
/// consumes the engine's snapshot stream and adds speed/ETA (rolling
/// average) which are presentation concerns, not engine state.
@MainActor @Observable
final class TransferQueueModel {
    struct Row: Identifiable {
        let id: UUID
        var name: String
        var detail: String
        var direction: TransferRequest.Direction
        var phase: TransferSnapshot.Phase
        var fraction: Double?
        var metaText: String
        var badgeText: String
    }

    private(set) var rows: [Row] = []
    /// Called when an item completes so the destination pane can refresh.
    var onCompleted: ((TransferSnapshot) -> Void)?

    let engine: TransferEngine
    private var speedSamples: [UUID: (time: ContinuousClock.Instant, bytes: Int64, speed: Double)] = [:]
    // nonisolated(unsafe): written once in init, read in deinit — no races.
    nonisolated(unsafe) private var consumeTask: Task<Void, Never>?

    var activeCount: Int { rows.filter { $0.phase == .running }.count }
    var queuedCount: Int { rows.filter { $0.phase == .queued }.count }
    var hasFinishedRows: Bool { rows.contains { $0.phase.isFinished } }

    init(engine: TransferEngine) {
        self.engine = engine
        consumeTask = Task { [weak self, engine] in
            for await snapshot in await engine.events() {
                guard let self else { break }
                self.apply(snapshot)
            }
        }
    }

    deinit {
        consumeTask?.cancel()
    }

    func enqueue(_ request: TransferRequest) {
        Task { await engine.enqueue(request) }
    }

    func cancel(id: UUID) {
        Task { await engine.cancel(id: id) }
    }

    func clearFinished() {
        rows.removeAll { $0.phase.isFinished }
        Task { await engine.clearFinished() }
    }

    private func apply(_ snapshot: TransferSnapshot) {
        let wasFinished = rows.first { $0.id == snapshot.id }?.phase.isFinished ?? false
        let row = makeRow(snapshot)
        if let index = rows.firstIndex(where: { $0.id == snapshot.id }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
        if snapshot.phase == .completed, !wasFinished {
            onCompleted?(snapshot)
        }
        if snapshot.phase.isFinished {
            speedSamples.removeValue(forKey: snapshot.id)
        }
    }

    private func makeRow(_ snapshot: TransferSnapshot) -> Row {
        let fraction: Double?
        if let total = snapshot.totalBytes, total > 0 {
            fraction = min(1, Double(snapshot.bytesTransferred) / Double(total))
        } else {
            fraction = snapshot.phase == .completed ? 1 : nil
        }

        return Row(id: snapshot.id,
                   name: snapshot.displayName,
                   detail: "\(snapshot.sourcePath)  →  \(snapshot.destinationPath)",
                   direction: snapshot.direction,
                   phase: snapshot.phase,
                   fraction: fraction,
                   metaText: metaText(for: snapshot),
                   badgeText: badgeText(for: snapshot.phase))
    }

    private func metaText(for snapshot: TransferSnapshot) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: snapshot.bytesTransferred, countStyle: .file)
        switch snapshot.phase {
        case .queued:
            return "waiting"
        case .running:
            let total = snapshot.totalBytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "?"
            var text = "\(bytes) of \(total)"
            if let speed = updateSpeed(for: snapshot), speed > 1 {
                text += " · \(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s"
                if let remaining = snapshot.totalBytes.map({ $0 - snapshot.bytesTransferred }),
                   remaining > 0 {
                    let seconds = Int(Double(remaining) / speed)
                    text += " · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
                }
            }
            return text
        case .completed:
            return bytes
        case .failed(let message):
            return message
        case .cancelled:
            return "cancelled at \(bytes)"
        }
    }

    /// Exponentially smoothed transfer speed in bytes/second.
    private func updateSpeed(for snapshot: TransferSnapshot) -> Double? {
        let now = ContinuousClock.now
        defer {
            let previous = speedSamples[snapshot.id]
            let speed: Double
            if let previous, snapshot.bytesTransferred > previous.bytes {
                let dt = Double((now - previous.time).components.attoseconds) / 1e18
                    + Double((now - previous.time).components.seconds)
                let instantaneous = Double(snapshot.bytesTransferred - previous.bytes) / max(dt, 0.001)
                speed = previous.speed == 0 ? instantaneous : 0.3 * instantaneous + 0.7 * previous.speed
            } else {
                speed = previous?.speed ?? 0
            }
            speedSamples[snapshot.id] = (now, snapshot.bytesTransferred, speed)
        }
        return speedSamples[snapshot.id]?.speed
    }

    private func badgeText(for phase: TransferSnapshot.Phase) -> String {
        switch phase {
        case .queued: "QUEUED"
        case .running: "TRANSFERRING"
        case .completed: "DONE"
        case .failed: "ERROR"
        case .cancelled: "CANCELLED"
        }
    }
}
