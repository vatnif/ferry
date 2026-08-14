import AppKit
import FerryCore
import UniformTypeIdentifiers

/// Owns the AppKit side of remote→Finder drag-out (ADR-038).
///
/// One per `BrowserSession`, never per row: `NSFilePromiseProvider.delegate` is
/// a **weak** reference and SwiftUI recycles `Table` cell views, so a row-owned
/// delegate can be deallocated mid-drag — the promise would then never resolve
/// and Finder would wait forever with no error. The bridge is also the
/// `NSDraggingSource` for the same reason.
/// (`NSObject` because `NSDraggingSource` refines `NSObjectProtocol`.)
@MainActor
final class RemoteDragBridge: NSObject {
    /// Promise delegates, retained until each promise resolves (the provider
    /// only holds them weakly).
    private var promises: [UUID: NSObject] = [:]
    /// Which delegates each in-flight drag session created, so a drag that
    /// ends without a drop can release them — Finder never requests those
    /// promises, so `onFinish` would never run.
    private var sessionTokens: [ObjectIdentifier: [UUID]] = [:]

    /// Checkpoint-A spike switch: vend a stub promise that reports fake bytes
    /// for `stubDuration` and then writes a 10-byte file, instead of running a
    /// real download. Proves deferred completion, the Finder progress question
    /// and the hit-testing questions without any engine work.
    var useStubPromise = true
    var stubDuration: Duration = .seconds(30)

    /// Starts a drag session for `items` out of the remote pane. `iconFrame` is
    /// the handle's bounds, so the drag image lifts off the icon in place.
    func beginDrag(_ items: [FileItem],
                   pane: PaneModel,
                   from view: NSView,
                   event: NSEvent,
                   iconFrame: NSRect) {
        guard !items.isEmpty else { return }
        var draggingItems: [NSDraggingItem] = []
        var tokens: [UUID] = []
        for (index, item) in items.enumerated() {
            guard let (provider, token) = makeProvider(for: item) else { continue }
            tokens.append(token)
            let draggingItem = NSDraggingItem(pasteboardWriter: provider)
            // Stack multi-item drags with a small offset — AppKit then draws
            // its own count badge.
            let offset = CGFloat(index) * 4
            draggingItem.setDraggingFrame(iconFrame.offsetBy(dx: offset, dy: -offset),
                                          contents: Self.dragImage(for: item))
            draggingItems.append(draggingItem)
        }
        guard !draggingItems.isEmpty else { return }
        let session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
        sessionTokens[ObjectIdentifier(session)] = tokens

        // The inter-pane payload needs its OWN pasteboard item: SwiftUI's drop
        // machinery reads NOTHING off an item that also carries file-promise
        // types — measured even for `.string`, and again for the declared type
        // (ADR-038). AppKit reads the same item fine, so this is SwiftUI's
        // decoding, not the pasteboard.
        //
        // But it must NOT be its own *dragging item*: Finder's count badge
        // counts dragging items regardless of type (measured — a
        // non-Finder-consumable declared type still badged "2" per row), so the
        // payload items are appended straight to the drag pasteboard instead.
        //
        // The payload travels under Ferry's DECLARED drag type (Info.plist
        // `UTExportedTypeDeclarations` — an undeclared identifier decodes zero
        // items, also measured), not `.string`: the private type cannot paste
        // `ferryitem|…` text into other apps.
        let payloads = items.map { item -> NSPasteboardItem in
            let payload = NSPasteboardItem()
            payload.setData(Data(FileBrowserPane.dragPayload(for: item, in: pane).utf8),
                            forType: NSPasteboard.PasteboardType(RemoteDragPayload.typeIdentifier))
            return payload
        }
        session.draggingPasteboard.writeObjects(payloads)
    }

    private func makeProvider(for item: FileItem) -> (NSFilePromiseProvider, UUID)? {
        // Checkpoint A: the stub measures Finder's behaviour. Checkpoint C
        // replaces this with PromisedRemoteDownload (real engine transfer).
        guard useStubPromise else { return nil }
        let token = UUID()
        let delegate = StubPromisedDownload(item: item, duration: stubDuration) { [weak self] in
            self?.promises.removeValue(forKey: token)
        }
        let provider = NSFilePromiseProvider(fileType: Self.fileType(for: item).identifier,
                                             delegate: delegate)
        promises[token] = delegate
        return (provider, token)
    }

    /// Promised folders must advertise `public.folder`; files map from their
    /// extension so Finder shows the right icon while it waits.
    private static func fileType(for item: FileItem) -> UTType {
        if item.isDirectory { return .folder }
        let ext = (item.name as NSString).pathExtension
        guard !ext.isEmpty else { return .data }
        return UTType(filenameExtension: ext.lowercased()) ?? .data
    }

    /// Lifts the same SF Symbol that is already the drag handle, so the drag
    /// looks exactly as it does today (approved: icon only, no filename).
    private static func dragImage(for item: FileItem) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [
                item.isDirectory ? .controlAccentColor : .secondaryLabelColor
            ]))
        return NSImage(systemSymbolName: item.iconName, accessibilityDescription: item.name)?
            .withSymbolConfiguration(configuration)
    }
}

extension RemoteDragBridge: @preconcurrency NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy in both contexts: outside the app Finder downloads a copy;
        // inside it, the other pane enqueues a transfer (nothing is moved).
        .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard let tokens = sessionTokens.removeValue(forKey: ObjectIdentifier(session)) else { return }
        // No drop happened, so nothing will ever request these promises —
        // release the delegates now or they leak. On a real drop the receiver
        // may fulfil the promise well AFTER the session ends; those delegates
        // stay retained until their own `onFinish`.
        guard operation.isEmpty else { return }
        for token in tokens {
            promises.removeValue(forKey: token)
        }
    }
}
/// Checkpoint-A stub: holds the promise open for `duration` while reporting
/// fake byte progress, then writes 10 bytes. Deliberately dumb — its only job
/// is to answer the questions in the ADR-038 measurement matrix.
private final class StubPromisedDownload: NSObject {
    /// The promise's completion handler is not `Sendable`, but every touch of it
    /// is main-actor-isolated — `operationQueue(for:)` returns `.main`, the
    /// delegate callback runs there, and the Task that calls it is `@MainActor`.
    /// That discipline is what makes the box safe.
    struct SendableCompletion: @unchecked Sendable {
        let call: (Error?) -> Void
    }

    private let item: FileItem
    private let duration: Duration
    private let onFinish: @MainActor () -> Void
    private var claimed = false

    init(item: FileItem, duration: Duration, onFinish: @MainActor @escaping () -> Void) {
        self.item = item
        self.duration = duration
        self.onFinish = onFinish
    }
}

extension StubPromisedDownload: @preconcurrency NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        item.name
    }

    /// All delegate callbacks land on the main actor, matching the
    /// `@preconcurrency` conformance. Nothing here blocks it: the method
    /// returns immediately and the handler fires from the Task.
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        .main
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard !claimed else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        claimed = true
        FerryLog.debug("drag-out spike: Finder asked for \(url.path)")

        let total: Int64 = 10_000_000
        let progress = Progress(parent: nil, userInfo: [
            .fileOperationKindKey: Progress.FileOperationKind.downloading,
            .fileURLKey: url
        ])
        progress.kind = .file
        progress.isCancellable = true
        progress.totalUnitCount = total
        progress.publish()

        let completion = SendableCompletion(call: completionHandler)
        Task { @MainActor [duration, onFinish, item] in
            let ticks = 60
            let step = duration / ticks
            for tick in 1...ticks {
                try? await Task.sleep(for: step)
                progress.completedUnitCount = total / Int64(ticks) * Int64(tick)
            }
            progress.unpublish()
            do {
                // A promised folder must become a real directory at `url` —
                // writing a plain file there is what made the checkpoint-A
                // folder drags look broken.
                if item.isDirectory {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try Data("spike\n".utf8).write(to: url.appendingPathComponent("spike.txt"))
                } else {
                    try Data("spike\n".utf8).write(to: url)
                }
                FerryLog.debug("drag-out spike: wrote \(url.lastPathComponent) after \(duration)")
                completion.call(nil)
            } catch {
                FerryLog.error("drag-out spike: write failed — \(error.localizedDescription)")
                completion.call(error)
            }
            onFinish()
        }
    }
}
