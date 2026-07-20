import Foundation

/// Watches a single file for content changes and emits coalesced change
/// notifications on an `AsyncStream`. Backs the editor round-trip (M19): the
/// editing-sessions tracker starts one `FileWatcher` per file handed to an
/// external editor, and each emission triggers an upload of the (edited) temp
/// copy back to the server.
///
/// Pure Foundation/Dispatch — no AppKit — so it lives in FerryCore and is
/// headless-testable against real temp files.
///
/// Two subtleties it handles, both covered by `FileWatcherTests`:
///  * **Coalescing** — a single editor save often produces several
///    `.write`/`.extend` vnode events; they are debounced into one emission so
///    the round-trip enqueues one upload per save, not several.
///  * **Atomic saves** — many editors (BBEdit, VS Code, vim with default
///    settings) save by writing a sibling temp file and `rename(2)`-ing it over
///    the target. That replaces the inode, so the `O_EVTONLY` descriptor stops
///    receiving events. On a `.delete`/`.rename`/`.revoke` event the watcher
///    re-opens the path (the freshly renamed-in file) and re-arms, still
///    emitting one change for the save.
///
/// Thread-safety: every piece of mutable state is confined to the private
/// serial `queue`; the type is `@unchecked Sendable` on that discipline.
public final class FileWatcher: @unchecked Sendable {

    /// Coalesced change notifications. One `()` per settled save. The stream
    /// finishes when `cancel()` is called (or the watcher is deallocated).
    public let changes: AsyncStream<Void>

    private let path: String
    private let debounce: DispatchTimeInterval
    private let queue = DispatchQueue(label: "com.gfragos.Ferry.FileWatcher")
    private let continuation: AsyncStream<Void>.Continuation

    // Confined to `queue`.
    private var source: (any DispatchSourceFileSystemObject)?
    private var descriptor: Int32 = -1
    private var pendingEmit = false
    private var cancelled = false

    /// - Parameters:
    ///   - path: the file to watch (it must exist when watching starts).
    ///   - debounceMilliseconds: how long to coalesce a burst of write events
    ///     into a single emission. 200 ms comfortably covers a normal save.
    public init(path: String, debounceMilliseconds: Int = 200) {
        self.path = path
        self.debounce = .milliseconds(debounceMilliseconds)
        var captured: AsyncStream<Void>.Continuation!
        self.changes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
        self.continuation = captured
        queue.async { [weak self] in self?.arm() }
    }

    deinit {
        // Best-effort teardown if the owner forgot to cancel.
        source?.cancel()
        continuation.finish()
    }

    /// Stops watching and finishes the stream. Idempotent.
    public func cancel() {
        queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.cancelled = true
            self.source?.cancel()   // cancel handler closes the descriptor
            self.source = nil
            self.continuation.finish()
        }
    }

    // MARK: - Private (all on `queue`)

    private func arm() {
        guard !cancelled else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // The path is momentarily absent (e.g. mid-atomic-save). Retry.
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                self?.arm()
            }
            return
        }
        descriptor = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke, .link],
            queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                // The watched inode is gone (atomic save / move). Re-open the
                // path and still emit one change for this save.
                self.reArm()
            }
            self.scheduleEmit()
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    /// Tear down the current source and re-open the path shortly after (the
    /// renamed-in file needs a beat to settle).
    private func reArm() {
        source?.cancel()
        source = nil
        descriptor = -1
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.arm()
        }
    }

    /// Debounce: collapse a burst of events into a single emission.
    private func scheduleEmit() {
        guard !cancelled, !pendingEmit else { return }
        pendingEmit = true
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self else { return }
            self.pendingEmit = false
            guard !self.cancelled else { return }
            self.continuation.yield(())
        }
    }
}
