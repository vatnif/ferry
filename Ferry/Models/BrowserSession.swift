import SwiftUI
import FerryCore

/// State of one browser pane (local or remote) — DESIGN.md screen 1.
/// Both panes are instances of this class over different FileSystemSources.
@MainActor @Observable
final class PaneModel: Identifiable {
    enum Kind { case local, remote }

    let kind: Kind
    let source: any FileSystemSource

    private(set) var path: String = "/"
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    var errorMessage: String?
    var includeHidden = false {
        didSet { Task { await reload() } }
    }
    var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\.name)]
    var selection = Set<FileItem.ID>()
    /// Sync-browsing miss feedback: briefly true → path bar flashes.
    private(set) var flashPathBar = false

    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []

    init(kind: Kind, source: any FileSystemSource) {
        self.kind = kind
        self.source = source
    }

    /// Items after sorting (directories first, then the active comparator).
    /// Text filtering happens in the view via BrowserSession.filterText.
    var sortedItems: [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            for comparator in sortOrder {
                switch comparator.compare(lhs, rhs) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func load(_ newPath: String, recordHistory: Bool = true) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let listing = try await source.list(directory: newPath, includeHidden: includeHidden)
            if recordHistory, path != newPath {
                backStack.append(path)
                forwardStack.removeAll()
            }
            path = newPath
            items = listing
            selection.removeAll()
        } catch {
            errorMessage = Self.describe(error, path: newPath)
        }
    }

    func reload() async {
        let current = path
        do {
            items = try await source.list(directory: current, includeHidden: includeHidden)
        } catch {
            errorMessage = Self.describe(error, path: current)
        }
    }

    func goBack() async {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        await load(previous, recordHistory: false)
    }

    func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        await load(next, recordHistory: false)
    }

    func flashMissingCounterpart() {
        flashPathBar = true
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            flashPathBar = false
        }
    }

    // MARK: File operations (M10)

    /// Renames `item` in place (same directory). Rejects empty names, names
    /// containing "/", and no-ops when unchanged. On success reloads the pane.
    func rename(_ item: FileItem, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        guard !trimmed.contains("/") else {
            errorMessage = "A file name can’t contain “/”."
            return
        }
        let parent = (item.path as NSString).deletingLastPathComponent
        let destination = PathUtilities.join(parent, trimmed)
        do {
            try await source.rename(from: item.path, to: destination)
            await reload()
        } catch {
            errorMessage = Self.describe(error, path: item.path)
        }
    }

    /// Deletes every item (directories recursively — the UI confirms first).
    /// Continues past a failure so one bad item doesn't strand the rest; the
    /// last error is surfaced and the pane reloads to reflect what remains.
    func delete(_ items: [FileItem]) async {
        var failure: Error?
        var failedPath = ""
        for item in items {
            do {
                try await source.delete(at: item.path)
            } catch {
                failure = error
                failedPath = item.path
            }
        }
        await reload()
        if let failure { errorMessage = Self.describe(failure, path: failedPath) }
    }

    /// Applies POSIX permissions to `item` (chmod editor). Reloads so the
    /// Perms column reflects the change.
    func applyPermissions(_ permissions: FilePermissions, to item: FileItem) async {
        do {
            try await source.setPermissions(permissions, at: item.path)
            await reload()
        } catch {
            errorMessage = Self.describe(error, path: item.path)
        }
    }

    /// Resolves a local file URL suitable for Quick Look. Local files preview
    /// in place; remote files are streamed into a temp file first
    /// (DOMAIN.md → download-and-Quick-Look). Directories aren't previewed.
    func previewURL(for item: FileItem) async -> URL? {
        guard !item.isDirectory else { return nil }
        if kind == .local {
            return URL(fileURLWithPath: item.path)
        }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("FerryQuickLook", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(item.name)
            try? FileManager.default.removeItem(at: destination)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            for try await chunk in try await source.openRead(at: item.path, offset: 0) {
                try handle.write(contentsOf: chunk)
            }
            return destination
        } catch {
            errorMessage = Self.describe(error, path: item.path)
            return nil
        }
    }

    static func describe(_ error: Error, path: String) -> String {
        guard let sourceError = error as? FileSystemSourceError else {
            return error.localizedDescription
        }
        switch sourceError {
        case .notFound: return "“\(path)” does not exist on this side."
        case .notADirectory: return "“\(path)” is not a folder."
        case .permissionDenied: return "You don’t have permission to open “\(path)”."
        case .alreadyExists: return "“\(path)” already exists."
        case .invalidOffset: return "Internal error: invalid file offset."
        case .unsupported(let operation): return "Not available yet: \(operation)."
        case .io(let detail): return "I/O error: \(detail)"
        }
    }
}

/// A live connection shown in the detail area: local pane + remote pane,
/// navigation (with optional sync browsing), and connection metadata.
@MainActor @Observable
final class BrowserSession {
    /// Status-bar projection of the ConnectionSupervisor state (M9).
    enum Health: Equatable {
        case connected
        case reconnecting(attempt: Int)
        case lost
    }

    let profile: ConnectionProfile
    let local: PaneModel
    let remote: PaneModel
    let queue: TransferQueueModel
    /// Group-completion signals over the SAME engine as `queue` (ADR-038):
    /// a Finder drag-out signals its promise only when every member of the
    /// dragged tree has finished, never when the root directory has merely
    /// enqueued its children.
    let groups: TransferGroupTracker
    /// AppKit plumbing for remote→Finder drag-out (ADR-038). Session-scoped
    /// because it must retain each promise's delegate until the promise
    /// resolves — a `Table` row view can be recycled mid-drag.
    let drag = RemoteDragBridge()
    /// Port-forward manager (SSH-based profiles only; nil for FTP/FTPS). Runs
    /// its own SSH session — see `TunnelEngine` (M14).
    let tunnels: TunnelController?
    /// The embedded terminal (screen 7, M15.5) — SSH profiles on macOS 15+
    /// only, nil otherwise. Type-erased because `TerminalController` is
    /// macOS-15-gated and this class isn't; use the `terminal` accessor.
    private let terminalStorage: Any?

    @available(macOS 15.0, *)
    var terminal: TerminalController? { terminalStorage as? TerminalController }
    /// The live remote connection (SFTP or FTP/FTPS) — held via the composed
    /// protocol so the session is backend-agnostic (M12).
    private let remoteConnection: any FileSystemSource & SupervisedConnection
    /// Keep-alive + auto-reconnect; nil when the profile's keep-alive is off
    /// (DOMAIN.md ties both to the same flag).
    private let supervisor: ConnectionSupervisor?
    // nonisolated(unsafe): written once in start(), cancelled in disconnect().
    nonisolated(unsafe) private var supervisorTask: Task<Void, Never>?

    private(set) var health: Health = .connected

    /// Toolbar filter — applies to the focused (active) pane, per DESIGN.md.
    var filterText = ""
    var activePaneKind: PaneModel.Kind = .remote

    /// Presentation state for this session's own modal decisions (ADR-035).
    /// It lives here rather than in `BrowserView`'s `@State` because every
    /// connected tab renders that view at the same structural position: SwiftUI
    /// shares one instance's state across tabs, so staging started in one tab
    /// could surface its alert over another and act on *its* session.
    var pendingConflicts: [TransferRequest] = []
    var pendingResumeDecisions: [ResumeDecision] = []
    var showTunnels = false
    /// Non-nil presents the New Folder alert, holding the typed name.
    var newFolderName: String?

    /// Sync browsing (DESIGN.md screen 1): anchors are captured when the
    /// link is switched on; navigation mirrors relative paths.
    private(set) var linked = false
    private var localAnchor = "/"
    private var remoteAnchor = "/"

    /// Round-trip of one stat call at connect time (status bar).
    private(set) var pingMilliseconds: Int?

    /// Files currently open in an external editor (M19 editor round-trip),
    /// keyed by remote path. Torn down in `disconnect()` (which the tab close
    /// also calls, ConnectionManagerModel.teardownSession).
    private var editingSessions: [String: EditingSession] = [:]

    var activePane: PaneModel { activePaneKind == .local ? local : remote }

    init(profile: ConnectionProfile,
         remote: any FileSystemSource & SupervisedConnection,
         bookmarks: SecurityScopedBookmarkStore?,
         tunnels: TunnelController? = nil,
         terminal: Any? = nil) {
        self.profile = profile
        self.remoteConnection = remote
        self.tunnels = tunnels
        self.terminalStorage = terminal
        self.local = PaneModel(kind: .local, source: LocalFileSource(bookmarks: bookmarks))
        self.remote = PaneModel(kind: .remote, source: remote)
        self.supervisor = profile.keepAlive ? ConnectionSupervisor(connection: remote) : nil
        // Engine tunables come from Settings ▸ Transfers (M16, ADR-026),
        // read once per connection (DOMAIN.md default is 3 concurrent). The
        // conflict/interrupted policies are re-read at each staging call so
        // they apply immediately.
        let settings = TransferSettingsSnapshot.current
        // The queue model and the group tracker must observe the SAME engine —
        // and the tracker must be constructed with it (a late subscriber could
        // miss members and vacuously conclude a group).
        let engine = TransferEngine(
            maxConcurrent: settings.simultaneous,
            maxAttempts: settings.maxAttempts,
            retryDelay: settings.retryDelay)
        self.queue = TransferQueueModel(engine: engine)
        self.groups = TransferGroupTracker(engine: engine)
        drag.session = self
        queue.onCompleted = { [weak self] snapshot in
            guard let self else { return }
            let destination = snapshot.direction == .download ? self.local : self.remote
            Task { await destination.reload() }
            self.completedSinceIdle += 1
            self.notifyIfQueueDrained()
        }
        // A transfer that exhausted its retries often means the connection
        // dropped — let the supervisor check and reconnect (DOMAIN.md:
        // in-flight transfers re-queue as resumable; the user retries the
        // ERROR row once the link is back). Also re-checks the drain so a queue
        // whose last event is a failure still notifies for its completed items.
        queue.onFailed = { [weak self] snapshot in
            guard let self else { return }
            FerryLog.error("Transfer failed: \(snapshot.displayName)")
            self.notifyIfQueueDrained()
            if let supervisor = self.supervisor {
                Task { await supervisor.noteFailure() }
            }
        }
    }

    /// Loads both panes' start paths. Called once right after connect.
    func start() async {
        let localStart: String
        if let configured = profile.localStartPath, !configured.isEmpty {
            localStart = NSString(string: configured).expandingTildeInPath
        } else if let folder = Self.defaultLocalFolder {
            // Settings ▸ General default local folder (M16), used only when the
            // profile doesn't pin its own local start path.
            localStart = folder
        } else {
            localStart = (try? await local.source.homeDirectory()) ?? NSHomeDirectory()
        }

        let remoteStart: String
        if let configured = profile.remoteStartPath, !configured.isEmpty {
            remoteStart = configured
        } else {
            remoteStart = (try? await remote.source.homeDirectory()) ?? "/"
        }

        let clock = ContinuousClock()
        let started = clock.now
        await remote.load(remoteStart, recordHistory: false)
        pingMilliseconds = Int((clock.now - started).components.attoseconds / 1_000_000_000_000_000)

        await local.load(localStart, recordHistory: false)

        if let supervisor {
            supervisorTask = Task { [weak self] in
                for await state in await supervisor.events() {
                    guard let self else { break }
                    self.applyHealth(state)
                }
            }
            await supervisor.start()
        }

        // Bring up saved tunnels the profile opted into auto-starting. The
        // tunnel engine only opens its (dedicated) SSH session if there's an
        // enabled tunnel to run, so this is free when there are none.
        if let tunnels, profile.autoStartsTunnels {
            tunnels.startEnabled(profile.tunnels)
        }
    }

    private func applyHealth(_ state: ConnectionSupervisor.State) {
        let previous = health
        switch state {
        case .connected: health = .connected
        case .reconnecting(let attempt): health = .reconnecting(attempt: attempt)
        case .lost: health = .lost
        }
        // Recovered from a drop: the panes may be stale — reload in place
        // (DOMAIN.md: restore the panes' paths).
        if health == .connected, previous != .connected {
            Task {
                await remote.reload()
                await local.reload()
            }
        }
    }

    /// Manual retry from the status bar once the link is declared lost.
    func reconnectNow() {
        guard let supervisor else { return }
        Task { await supervisor.reconnectNow() }
    }

    func disconnect() async {
        endAllEditingSessions()
        supervisorTask?.cancel()
        await supervisor?.stop()
        await tunnels?.shutdown()
        await remoteConnection.disconnect()
    }

    func setLinked(_ on: Bool) {
        linked = on
        if on {
            localAnchor = local.path
            remoteAnchor = remote.path
        }
    }

    /// All user navigation goes through here so sync browsing can mirror it.
    func navigate(_ pane: PaneModel, to path: String) {
        Task {
            await pane.load(path)
            guard linked else { return }
            await mirror(from: pane, newPath: path)
        }
    }

    func goBack(_ pane: PaneModel) {
        Task {
            await pane.goBack()
            if linked { await mirror(from: pane, newPath: pane.path) }
        }
    }

    func goForward(_ pane: PaneModel) {
        Task {
            await pane.goForward()
            if linked { await mirror(from: pane, newPath: pane.path) }
        }
    }

    /// DESIGN.md contract: mirror the relative path under the anchors; if the
    /// counterpart folder is missing, the other pane stays put and flashes —
    /// the link is kept.
    private func mirror(from pane: PaneModel, newPath: String) async {
        let other = pane.kind == .local ? remote : local
        let (fromAnchor, toAnchor) = pane.kind == .local
            ? (localAnchor, remoteAnchor)
            : (remoteAnchor, localAnchor)

        guard let relative = PathUtilities.relativePath(of: newPath, under: fromAnchor) else {
            return // navigated outside the anchor: nothing to mirror, link kept
        }
        let target = relative.isEmpty ? toAnchor : PathUtilities.join(toAnchor, relative)
        guard target != other.path else { return }

        do {
            let stat = try await other.source.stat(path: target)
            guard stat.isDirectory else {
                other.flashMissingCounterpart()
                return
            }
            await other.load(target)
        } catch {
            other.flashMissingCounterpart()
        }
    }

    static func join(_ base: String, _ relative: String) -> String {
        PathUtilities.join(base, relative)
    }

    // MARK: Transfers (M8; folders + resume M9; policies M16 / ADR-026)

    /// An interrupted download whose `.ferrypart` can be resumed — surfaced to
    /// the UI when the interrupted-transfer policy is **Ask** (Settings ▸
    /// Transfers). The user picks Resume (continue) or Start Over (restart).
    struct ResumeDecision: Identifiable {
        let id = UUID()
        var request: TransferRequest
        var partialBytes: Int64
        var displayName: String { request.displayName }
    }

    /// What staging produced that still needs a user decision: conflicts (the
    /// **Ask** exists-policy) and resume decisions (the **Ask** interrupted
    /// policy). Everything else has already been enqueued.
    struct StagingResult {
        var conflicts: [TransferRequest] = []
        var resumeDecisions: [ResumeDecision] = []
    }

    /// Stages transfers of `items` from `pane` into the opposite pane's current
    /// directory, applying the Settings ▸ Transfers policies (M16, ADR-026):
    /// - **exists** policy (destination already present): Overwrite (restart),
    ///   Ask (returned for the per-file dialog), Skip (dropped), Rename (a
    ///   `name 2.ext` copy is enqueued).
    /// - **interrupted** policy (a resumable `.ferrypart` exists, no final
    ///   file): Resume (automatic), Restart, or Ask (returned as a decision).
    func stageTransfers(_ items: [FileItem], from pane: PaneModel) async -> StagingResult {
        let destinationPane = pane.kind == .local ? remote : local
        let settings = TransferSettingsSnapshot.current
        var result = StagingResult()
        var takenNames = Set(destinationPane.items.map(\.name))

        for item in items {
            var request = TransferRequest(
                direction: pane.kind == .local ? .upload : .download,
                kind: item.isDirectory ? .directory : .file,
                mode: settings.interruptedPolicy.transferMode,
                source: pane.source, sourcePath: item.path,
                destination: destinationPane.source,
                destinationPath: Self.join(destinationPane.path, item.name),
                displayName: item.name,
                knownSize: item.isDirectory ? nil : item.size)

            let destinationExists = (try? await destinationPane.source.stat(path: request.destinationPath)) != nil
            if destinationExists {
                switch settings.existsPolicy {
                case .ask:
                    result.conflicts.append(request)
                case .overwrite:
                    request.mode = .restart
                    queue.enqueue(request)
                case .skip:
                    continue
                case .rename:
                    let newName = TransferNaming.deduplicatedName(for: item.name, existing: takenNames)
                    takenNames.insert(newName)
                    queue.enqueue(TransferRequest(
                        direction: request.direction, kind: request.kind, mode: .automatic,
                        source: request.source, sourcePath: request.sourcePath,
                        destination: request.destination,
                        destinationPath: Self.join(destinationPane.path, newName),
                        displayName: newName,
                        knownSize: item.isDirectory ? nil : item.size))
                }
            } else {
                takenNames.insert(item.name)
                if settings.interruptedPolicy == .ask,
                   let bytes = await resumablePartialBytes(for: request) {
                    result.resumeDecisions.append(ResumeDecision(request: request, partialBytes: bytes))
                } else {
                    queue.enqueue(request)
                }
            }
        }
        return result
    }

    /// Stages files dropped from Finder (or dragged from the local pane, which
    /// vends file URLs) into `destinationPane`'s directory — uploads to a
    /// remote destination, local copies otherwise. Skips a URL already in the
    /// destination directory (a no-op self-drop). Applies the same exists
    /// policy as `stageTransfers`; interrupted-Ask doesn't apply (these are
    /// uploads/copies, where a smaller remote file is itself a conflict).
    func importFiles(_ urls: [URL], into destinationPane: PaneModel) async -> StagingResult {
        let localSource = local.source
        let direction: TransferRequest.Direction = destinationPane.kind == .remote ? .upload : .download
        let settings = TransferSettingsSnapshot.current
        var result = StagingResult()
        var takenNames = Set(destinationPane.items.map(\.name))

        for url in urls {
            let sourcePath = url.path
            let parent = (sourcePath as NSString).deletingLastPathComponent
            if destinationPane.kind == .local, parent == destinationPane.path { continue }
            guard let item = try? await localSource.stat(path: sourcePath) else { continue }
            var request = TransferRequest(
                direction: direction,
                kind: item.isDirectory ? .directory : .file,
                source: localSource, sourcePath: sourcePath,
                destination: destinationPane.source,
                destinationPath: Self.join(destinationPane.path, item.name),
                displayName: item.name,
                knownSize: item.isDirectory ? nil : item.size)

            let destinationExists = (try? await destinationPane.source.stat(path: request.destinationPath)) != nil
            if destinationExists {
                switch settings.existsPolicy {
                case .ask:
                    result.conflicts.append(request)
                case .overwrite:
                    request.mode = .restart
                    queue.enqueue(request)
                case .skip:
                    continue
                case .rename:
                    let newName = TransferNaming.deduplicatedName(for: item.name, existing: takenNames)
                    takenNames.insert(newName)
                    queue.enqueue(TransferRequest(
                        direction: request.direction, kind: request.kind, mode: .automatic,
                        source: request.source, sourcePath: request.sourcePath,
                        destination: request.destination,
                        destinationPath: Self.join(destinationPane.path, newName),
                        displayName: newName,
                        knownSize: item.isDirectory ? nil : item.size))
                }
            } else {
                takenNames.insert(item.name)
                queue.enqueue(request)
            }
        }
        return result
    }

    /// The resumable byte count of a download's `.ferrypart`, or nil when there
    /// is no valid partial to resume (matching the engine's rule: fresh, ≤ 30
    /// days, non-empty, not larger than the source). Only downloads have a
    /// `.ferrypart`; uploads resume via a smaller remote file (a conflict).
    private func resumablePartialBytes(for request: TransferRequest) async -> Int64? {
        guard request.direction == .download, request.kind == .file else { return nil }
        let partialPath = request.destinationPath + TransferEngine.partialSuffix
        guard let stat = try? await request.destination.stat(path: partialPath),
              !stat.isDirectory, let size = stat.size, size > 0,
              Self.isFreshPartial(stat.modifiedAt) else { return nil }
        if let total = (try? await request.source.stat(path: request.sourcePath))?.size, size > total {
            return nil
        }
        return size
    }

    private static func isFreshPartial(_ modifiedAt: Date?) -> Bool {
        guard let modifiedAt else { return true }
        return Date().timeIntervalSince(modifiedAt) <= 30 * 24 * 3600
    }

    /// Enqueues Replace choices: restart mode overwrites from byte 0 instead of
    /// resuming foreign partial data (for folders, merge-overwrites same-named
    /// children). Also serves the interrupted-Ask "Start Over" choice.
    func enqueueReplacing(_ requests: [TransferRequest]) {
        for var request in requests {
            request.mode = .restart
            queue.enqueue(request)
        }
    }

    /// Enqueues interrupted-Ask "Resume" choices: automatic mode continues the
    /// existing `.ferrypart`.
    func enqueueResuming(_ requests: [TransferRequest]) {
        for var request in requests {
            request.mode = .automatic
            queue.enqueue(request)
        }
    }

    // MARK: Finder drag-out (M21, ADR-038)

    /// Stages one remote→Finder drag-out. `destinationPath` is the exact path
    /// Finder chose: the NSFilePromiseReceiver resolves any name conflict in
    /// the drop folder before handing over the promise, so none of the pane
    /// exists/dedup/resume policy applies — and honouring that path is the
    /// contract. Mode is always `.restart` (ADR-038: the resume heuristic
    /// would silently append to a stranger's `.ferrypart` at the drop
    /// location, and a drag has no conflict prompt to reason about it).
    func beginDragOut(_ item: FileItem, to destinationPath: String) async
        -> (plan: DragOutPlan, handle: TransferGroupHandle) {
        let groupID = UUID()
        let destinationExisted = (try? await local.source.stat(path: destinationPath)) != nil
        let plan = DragOutPlan.make(item: item,
                                    destinationPath: destinationPath,
                                    source: remote.source,
                                    destination: local.source,
                                    destinationExisted: destinationExisted,
                                    groupID: groupID)
        // Open the group BEFORE enqueueing, and enqueue on the engine
        // directly — `queue.enqueue` spawns an unordered Task that could race
        // the registration, and a root enqueued before its group is seeded
        // would never conclude.
        let handle = await groups.open(group: groupID, root: plan.request.id)
        await queue.engine.enqueue(plan.request)
        return (plan, handle)
    }

    // MARK: Settings-derived helpers

    /// Settings ▸ General default local folder, or nil when unset/nonexistent.
    static var defaultLocalFolder: String? {
        guard let raw = UserDefaults.standard.string(forKey: AppSettings.Key.defaultLocalFolder),
              !raw.isEmpty else { return nil }
        let expanded = NSString(string: raw).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return expanded
    }

    /// Posts the queue-finished notification (Settings ▸ Transfers) once the
    /// queue drains, counting the transfers that completed since it was last
    /// idle. Called after each completion (which bumps the counter) and after
    /// each failure (so a queue ending in a failed item still notifies).
    private var completedSinceIdle = 0
    private func notifyIfQueueDrained() {
        guard queue.activeCount == 0, queue.queuedCount == 0 else { return }
        let count = completedSinceIdle
        completedSinceIdle = 0
        guard count > 0, TransferSettingsSnapshot.current.notifyOnFinished else { return }
        QueueNotifier.notifyQueueFinished(completed: count)
    }

    // MARK: Editor round-trip (M19)

    /// One file open in an external editor: the local temp copy and the watcher
    /// that re-uploads it on save. Lives only on the main actor (its owner is).
    private final class EditingSession {
        let remotePath: String
        let displayName: String
        let tempDirectory: URL
        let tempURL: URL
        let watcher: FileWatcher
        var task: Task<Void, Never>?

        init(remotePath: String, displayName: String,
             tempDirectory: URL, tempURL: URL, watcher: FileWatcher) {
            self.remotePath = remotePath
            self.displayName = displayName
            self.tempDirectory = tempDirectory
            self.tempURL = tempURL
            self.watcher = watcher
        }
    }

    /// Opens a **remote** file in an external editor and auto-uploads it back on
    /// every save (DOMAIN.md → Editor round-trip). `override` is a per-file
    /// "Open With ▸ app" choice (an application file-URL path) or nil for the
    /// Settings default. Direct builds only — launching another app can't work
    /// in the App Store sandbox (rule 5).
    func editRemoteFile(_ item: FileItem, override: String? = nil) {
        guard !item.isDirectory else { return }
        #if !APPSTORE
        let dispatch = EditorLaunchService.dispatch(override: override)
        guard case .launch(let target) = dispatch else {
            if case .unavailable(let reason) = dispatch { remote.errorMessage = reason }
            return
        }
        // Already editing this file → just re-open the same temp copy.
        if let existing = editingSessions[item.path] {
            Task { await launchEditor(existing.tempURL, target: target, side: remote) }
            return
        }
        Task {
            guard let staged = await stageForEditing(item) else { return }
            let watcher = FileWatcher(path: staged.tempURL.path)
            let session = EditingSession(remotePath: item.path, displayName: item.name,
                                         tempDirectory: staged.directory,
                                         tempURL: staged.tempURL, watcher: watcher)
            editingSessions[item.path] = session
            // Capture values (not the session) so the consumer task doesn't
            // retain-cycle it; teardown cancels the watcher + this task.
            let remotePath = item.path, tempPath = staged.tempURL.path, name = item.name
            session.task = Task { [weak self] in
                for await _ in watcher.changes {
                    guard let self else { break }
                    self.uploadEdit(remotePath: remotePath, tempPath: tempPath, displayName: name)
                }
            }
            await launchEditor(staged.tempURL, target: target, side: remote)
        }
        #else
        remote.errorMessage = EditorDispatch.appStoreUnavailable
        #endif
    }

    /// Opens a **local** file in an external editor, in place — no watcher or
    /// upload needed (editing a local file changes it directly).
    func editLocalFile(_ item: FileItem, override: String? = nil) {
        guard !item.isDirectory else { return }
        #if !APPSTORE
        let dispatch = EditorLaunchService.dispatch(override: override)
        guard case .launch(let target) = dispatch else {
            if case .unavailable(let reason) = dispatch { local.errorMessage = reason }
            return
        }
        Task { await launchEditor(URL(fileURLWithPath: item.path), target: target, side: local) }
        #else
        local.errorMessage = EditorDispatch.appStoreUnavailable
        #endif
    }

    /// Streams a remote file into a per-session unique temp directory
    /// (`FerryEdit/<uuid>/<name>`), so re-saves and same-named files never
    /// collide (unlike the shared Quick Look temp path). Returns nil on failure
    /// (surfaced on the remote pane).
    private func stageForEditing(_ item: FileItem) async -> (directory: URL, tempURL: URL)? {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("FerryEdit", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(item.name)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            for try await chunk in try await remote.source.openRead(at: item.path, offset: 0) {
                try handle.write(contentsOf: chunk)
            }
            return (directory, destination)
        } catch {
            remote.errorMessage = PaneModel.describe(error, path: item.path)
            return nil
        }
    }

    /// Enqueues an upload of the edited temp copy back to the original remote
    /// path. `.restart` overwrites from byte 0 (the whole edited file); the
    /// existing `queue.onCompleted` reloads the remote pane.
    private func uploadEdit(remotePath: String, tempPath: String, displayName: String) {
        queue.enqueue(TransferRequest(
            direction: .upload, kind: .file, mode: .restart,
            source: local.source, sourcePath: tempPath,
            destination: remote.source, destinationPath: remotePath,
            displayName: displayName))
    }

    #if !APPSTORE
    private func launchEditor(_ fileURL: URL, target: EditorTarget, side: PaneModel) async {
        do {
            try await ExternalEditorLauncher.launch(fileURL: fileURL, target: target)
        } catch {
            side.errorMessage = "Could not open the editor: \(error.localizedDescription)"
        }
    }
    #endif

    /// Cancels every editing watcher and removes the temp copies. Called from
    /// `disconnect()` (and thus tab close).
    private func endAllEditingSessions() {
        for session in editingSessions.values {
            session.watcher.cancel()
            session.task?.cancel()
            try? FileManager.default.removeItem(at: session.tempDirectory)
        }
        editingSessions.removeAll()
    }
}
