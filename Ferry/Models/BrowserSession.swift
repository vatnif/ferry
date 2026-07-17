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
            errorMessage = "A file name can't contain “/”."
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
        case .permissionDenied: return "You don't have permission to open “\(path)”."
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
    private let sftp: SFTPSource
    /// Keep-alive + auto-reconnect; nil when the profile's keep-alive is off
    /// (DOMAIN.md ties both to the same flag).
    private let supervisor: ConnectionSupervisor?
    // nonisolated(unsafe): written once in start(), cancelled in disconnect().
    nonisolated(unsafe) private var supervisorTask: Task<Void, Never>?

    private(set) var health: Health = .connected

    /// Toolbar filter — applies to the focused (active) pane, per DESIGN.md.
    var filterText = ""
    var activePaneKind: PaneModel.Kind = .remote

    /// Sync browsing (DESIGN.md screen 1): anchors are captured when the
    /// link is switched on; navigation mirrors relative paths.
    private(set) var linked = false
    private var localAnchor = "/"
    private var remoteAnchor = "/"

    /// Round-trip of one stat call at connect time (status bar).
    private(set) var pingMilliseconds: Int?

    var activePane: PaneModel { activePaneKind == .local ? local : remote }

    init(profile: ConnectionProfile, sftp: SFTPSource, bookmarks: SecurityScopedBookmarkStore?) {
        self.profile = profile
        self.sftp = sftp
        self.local = PaneModel(kind: .local, source: LocalFileSource(bookmarks: bookmarks))
        self.remote = PaneModel(kind: .remote, source: sftp)
        self.supervisor = profile.keepAlive ? ConnectionSupervisor(connection: sftp) : nil
        // DOMAIN.md: default 3 concurrent transfers per connection.
        self.queue = TransferQueueModel(engine: TransferEngine(maxConcurrent: 3))
        queue.onCompleted = { [weak self] snapshot in
            guard let self else { return }
            let destination = snapshot.direction == .download ? self.local : self.remote
            Task { await destination.reload() }
        }
        // A transfer that exhausted its retries often means the connection
        // dropped — let the supervisor check and reconnect (DOMAIN.md:
        // in-flight transfers re-queue as resumable; the user retries the
        // ERROR row once the link is back).
        queue.onFailed = { [weak self] _ in
            guard let supervisor = self?.supervisor else { return }
            Task { await supervisor.noteFailure() }
        }
    }

    /// Loads both panes' start paths. Called once right after connect.
    func start() async {
        let localStart: String
        if let configured = profile.localStartPath, !configured.isEmpty {
            localStart = NSString(string: configured).expandingTildeInPath
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
        supervisorTask?.cancel()
        await supervisor?.stop()
        await sftp.disconnect()
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

    // MARK: Transfers (M8; folders + resume M9)

    /// Enqueues transfers of `items` from `pane` into the opposite pane's
    /// current directory. Folders enqueue as directory items (the engine
    /// enumerates them lazily). Items whose destination already exists are
    /// NOT enqueued — they're returned for the UI's per-file ask dialog
    /// (DOMAIN.md conflict policy default: Ask). Non-conflicting items use
    /// `.automatic` mode, so an interrupted download's `.ferrypart` resumes
    /// without asking (interrupted policy default: resume automatically).
    func stageTransfers(_ items: [FileItem], from pane: PaneModel) async -> [TransferRequest] {
        let destinationPane = pane.kind == .local ? remote : local
        var conflicts: [TransferRequest] = []
        for item in items {
            let request = TransferRequest(
                direction: pane.kind == .local ? .upload : .download,
                kind: item.isDirectory ? .directory : .file,
                source: pane.source, sourcePath: item.path,
                destination: destinationPane.source,
                destinationPath: Self.join(destinationPane.path, item.name),
                displayName: item.name)
            if (try? await destinationPane.source.stat(path: request.destinationPath)) != nil {
                conflicts.append(request)
            } else {
                queue.enqueue(request)
            }
        }
        return conflicts
    }

    /// Enqueues transfers of files dropped from Finder (or dragged from the
    /// local pane, which vends file URLs) into `destinationPane`'s directory.
    /// Uploads when the destination is remote, local copies otherwise. Skips a
    /// URL already sitting in the destination directory (a no-op self-drop).
    /// Conflicting names are returned for the same per-file ask dialog as
    /// `stageTransfers` (DOMAIN.md).
    func importFiles(_ urls: [URL], into destinationPane: PaneModel) async -> [TransferRequest] {
        let localSource = local.source
        let direction: TransferRequest.Direction = destinationPane.kind == .remote ? .upload : .download
        var conflicts: [TransferRequest] = []
        for url in urls {
            let sourcePath = url.path
            let parent = (sourcePath as NSString).deletingLastPathComponent
            if destinationPane.kind == .local, parent == destinationPane.path { continue }
            guard let item = try? await localSource.stat(path: sourcePath) else { continue }
            let request = TransferRequest(
                direction: direction,
                kind: item.isDirectory ? .directory : .file,
                source: localSource, sourcePath: sourcePath,
                destination: destinationPane.source,
                destinationPath: Self.join(destinationPane.path, item.name),
                displayName: item.name)
            if (try? await destinationPane.source.stat(path: request.destinationPath)) != nil {
                conflicts.append(request)
            } else {
                queue.enqueue(request)
            }
        }
        return conflicts
    }

    /// Second phase after the user chose Replace: restart mode overwrites
    /// from byte 0 instead of resuming foreign partial data (for folders it
    /// merge-overwrites same-named children).
    func enqueueReplacing(_ requests: [TransferRequest]) {
        for var request in requests {
            request.mode = .restart
            queue.enqueue(request)
        }
    }
}
