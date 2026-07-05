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
    let profile: ConnectionProfile
    let local: PaneModel
    let remote: PaneModel
    private let sftp: SFTPSource

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
    }

    func disconnect() async {
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
}
