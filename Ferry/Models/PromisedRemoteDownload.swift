import AppKit
import FerryCore

/// Fulfils one Finder file promise with a real transfer through the session's
/// engine (ADR-038). Finder's completion is truthful: the handler is only
/// called once the group tracker reports every member of the dragged tree
/// finished — never when a directory has merely enqueued its children.
///
/// The completion handler here is the one sanctioned exception to the "no
/// completion handlers in new code" rule (ARCHITECTURE.md): the delegate
/// protocol is an OS-imposed boundary, and the handler's only job is to relay
/// what an `AsyncStream` already decided.
///
/// Not `@MainActor`: `NSFilePromiseProviderDelegate` is an @objc protocol, so
/// its witnesses cannot be actor-isolated. The discipline instead is the
/// checkpoint-A stub's: `operationQueue(for:)` returns `.main`, so every
/// callback (and every touch of `claimed`) runs on the main thread, and the
/// isolated work happens inside a `@MainActor` Task.
final class PromisedRemoteDownload: NSObject {
    /// Stages the drag-out on the owning BrowserSession, or nil when the
    /// session is gone (tab closed) — `@MainActor` so it is Sendable and the
    /// delegate never holds the non-Sendable session itself.
    typealias Begin = @MainActor (FileItem, String) async
        -> (plan: DragOutPlan, handle: TransferGroupHandle)?

    /// The promise's completion handler is not `Sendable`, but every touch of
    /// it is main-actor-isolated — `operationQueue(for:)` returns `.main`, the
    /// delegate callback runs there, and the Task that calls it is
    /// `@MainActor`. That discipline is what makes the box safe.
    private struct SendableCompletion: @unchecked Sendable {
        let call: (Error?) -> Void
    }

    private let item: FileItem
    private let begin: Begin
    private let onFinish: @MainActor () -> Void
    private var claimed = false

    init(item: FileItem,
         begin: @escaping Begin,
         onFinish: @MainActor @escaping () -> Void) {
        self.item = item
        self.begin = begin
        self.onFinish = onFinish
    }
}

extension PromisedRemoteDownload: @preconcurrency NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        item.name
    }

    /// All delegate callbacks land on the main thread, matching the
    /// `@preconcurrency` conformance. Nothing here blocks it: the method
    /// returns immediately and the handler fires from the Task.
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        .main
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        // Claim-once: a re-requested promise must not enqueue a second
        // transfer into the same destination.
        guard !claimed else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        claimed = true

        let completion = SendableCompletion(call: completionHandler)
        Task { @MainActor [item, begin, onFinish] in
            // Sandbox (rule 5): hold access to the drop folder for the
            // promise's whole lifetime, so a multi-minute transfer cannot
            // outlive the implicit grant Finder attached to the URL. In the
            // Direct build the call returns false and is a no-op.
            let dropDirectory = url.deletingLastPathComponent()
            let holdsScope = dropDirectory.startAccessingSecurityScopedResource()
            defer { if holdsScope { dropDirectory.stopAccessingSecurityScopedResource() } }

            guard let staged = await begin(item, url.path) else {
                // The tab closed while Finder held the promise — fail it
                // instead of hanging Finder forever.
                completion.call(CocoaError(.fileWriteUnknown))
                onFinish()
                return
            }
            // The handler fires exactly once; the stream may keep going after
            // it (a pause releases Finder but the group stays open so Resume
            // can still land the file).
            var signalled = false
            func signal(_ error: Error?) {
                guard !signalled else { return }
                signalled = true
                completion.call(error)
            }
            for await event in staged.handle.events {
                switch event {
                case .progress:
                    break // Ferry's queue dock shows progress; Finder shows
                          // none regardless (NSProgress measured a no-op).
                case .stalled:
                    // A member was paused: release Finder as a user-cancel
                    // (no alert), keep the row and its partial data.
                    signal(CocoaError(.userCancelled))
                case .finished(let outcome):
                    // Cleanup only here, never on `.stalled` — a paused drag
                    // keeps its `.ferrypart` so Resume still lands the file.
                    await staged.plan.cleanUp(after: outcome)
                    switch outcome {
                    case .completed:
                        signal(nil)
                    case .failed(let message):
                        // Finder's alert carries Ferry's own message.
                        signal(NSError(domain: NSCocoaErrorDomain,
                                       code: NSFileWriteUnknownError,
                                       userInfo: [NSLocalizedDescriptionKey: message]))
                    case .cancelled:
                        signal(CocoaError(.userCancelled))
                    }
                }
            }
            onFinish()
        }
    }
}
