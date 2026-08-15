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

    /// The owning BrowserSession — the promises download through its engine.
    /// Weak both ways: the session retains this bridge.
    weak var session: BrowserSession?

    /// Starts a drag session for `items` out of the remote pane. `iconFrame` is
    /// the handle's bounds, so the drag image lifts off the icon in place.
    ///
    /// Refuses to start (no dragging items are vended) when the pane is not
    /// remote or the connection is declared lost — a promise that can never be
    /// fulfilled would hang Finder. `.reconnecting` is NOT refused: the engine
    /// retries transient failures, so a queued row is the honest behaviour.
    func beginDrag(_ items: [FileItem],
                   pane: PaneModel,
                   from view: NSView,
                   event: NSEvent,
                   iconFrame: NSRect) {
        guard !items.isEmpty, pane.kind == .remote, session?.health != .lost,
              session != nil else { return }
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
        guard session != nil else { return nil }
        let token = UUID()
        // The delegate gets a closure, not the session: it re-resolves the
        // weak reference when Finder actually requests the promise, which can
        // be after the tab has closed — that must fail the promise, not hang.
        let delegate = PromisedRemoteDownload(item: item) { [weak self] item, path in
            guard let session = self?.session else { return nil }
            return await session.beginDragOut(item, to: path)
        } onFinish: { [weak self] in
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
