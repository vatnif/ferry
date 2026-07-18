import SwiftUI
import FerryCore

/// Main-actor projection of a connection's `TunnelEngine` for the tunnel
/// manager (DESIGN.md screen 4). Owns the dedicated tunnel SSH session, consumes
/// the engine's status stream, and exposes start/stop plus the live status for
/// each saved tunnel. Persistence of the tunnel list lives on
/// `ConnectionManagerModel` (it edits the profile); this class is runtime only.
@MainActor @Observable
final class TunnelController {
    /// Live phase per tunnel id; a tunnel the engine isn't tracking is stopped.
    private(set) var phases: [UUID: TunnelStatus.Phase] = [:]

    let engine: TunnelEngine
    // nonisolated(unsafe): written once in init, cancelled in deinit.
    nonisolated(unsafe) private var consumeTask: Task<Void, Never>?

    init(engine: TunnelEngine) {
        self.engine = engine
        consumeTask = Task { [weak self, engine] in
            for await snapshot in await engine.events() {
                guard let self else { break }
                for status in snapshot { self.phases[status.id] = status.phase }
            }
        }
    }

    deinit {
        consumeTask?.cancel()
    }

    func phase(for id: UUID) -> TunnelStatus.Phase { phases[id] ?? .stopped }

    /// Count of tunnels currently forwarding — the status-bar badge.
    var activeCount: Int {
        phases.values.filter { if case .forwarding = $0 { return true }; return false }.count
    }

    func start(_ config: TunnelConfiguration) {
        Task { await engine.start(config) }
    }

    func stop(_ id: UUID) {
        Task { await engine.stop(id) }
    }

    /// Auto-start enabled tunnels on connect (only when the profile opts in).
    func startEnabled(_ configs: [TunnelConfiguration]) {
        Task { await engine.startEnabled(configs) }
    }

    func shutdown() async {
        consumeTask?.cancel()
        await engine.shutdown()
    }
}
