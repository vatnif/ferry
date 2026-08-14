import AppKit
import FerryCore
import SwiftUI

/// Transparent AppKit overlay on a remote row's icon: the drag source for
/// remote→Finder drag-out (ADR-038).
///
/// It has to be AppKit. `NSFilePromiseProvider` is `NSPasteboardWriting`, not
/// `NSItemProvider`, so SwiftUI's `.draggable` cannot carry a file promise at
/// all — and CoreTransferable's `FileRepresentation` only ever hands Finder a
/// temp URL to copy from, which costs a second full copy and gives no control
/// over the destination.
///
/// The icon (not the row) stays the drag handle, per ADR-013. Because this view
/// owns the mouse handling it can also do what the old `.draggable` swallowed:
/// a double-click on the icon now runs the row's primary action.
struct RemoteDragHandle: NSViewRepresentable {
    let item: FileItem
    let pane: PaneModel
    let bridge: RemoteDragBridge
    /// Resolved at drag time, not at build time: the selection can change
    /// between rendering the row and starting the drag.
    let itemsToDrag: () -> [FileItem]
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DragHandleView {
        let view = DragHandleView()
        bind(view)
        return view
    }

    /// `Table` recycles cell views, so every property is rebound on update —
    /// a stale `item` here would drag the wrong file (the ADR-035 identity
    /// lesson, applied to an AppKit-backed view).
    func updateNSView(_ view: DragHandleView, context: Context) {
        bind(view)
    }

    private func bind(_ view: DragHandleView) {
        view.item = item
        view.pane = pane
        view.bridge = bridge
        view.itemsToDrag = itemsToDrag
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
    }
}

/// Invisible 16×16-ish hit area that starts the promise drag.
final class DragHandleView: NSView {
    var item: FileItem?
    var pane: PaneModel?
    var bridge: RemoteDragBridge?
    var itemsToDrag: (() -> [FileItem])?
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    /// Distance the mouse must travel before this becomes a drag rather than a
    /// click — without it, `mouseDown` would eat plain clicks and selection.
    private static let dragThreshold: CGFloat = 3
    private var mouseDownPoint: NSPoint?
    private var draggingStarted = false

    /// Let the user drag straight out of an unfocused Ferry window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// SwiftUI sizes the overlay to the icon it covers.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func mouseDown(with event: NSEvent) {
        // ⌘/⇧ clicks are selection edits (toggle / extend). The table owns
        // those semantics — hand the event up the responder chain (like
        // right-clicks below) instead of reimplementing them here, where a
        // plain `selectOnly` would collapse the selection.
        if !event.modifierFlags.intersection([.command, .shift]).isEmpty {
            mouseDownPoint = nil
            draggingStarted = false
            super.mouseDown(with: event)
            return
        }
        mouseDownPoint = event.locationInWindow
        draggingStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !draggingStarted, let start = mouseDownPoint else { return }
        let travelled = hypot(event.locationInWindow.x - start.x,
                              event.locationInWindow.y - start.y)
        guard travelled > Self.dragThreshold else { return }
        guard let bridge, let pane, let items = itemsToDrag?(), !items.isEmpty else { return }
        draggingStarted = true
        bridge.beginDrag(items, pane: pane, from: self, event: event, iconFrame: bounds)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            draggingStarted = false
        }
        // `mouseDownPoint == nil` means the down-event was forwarded to the
        // table (modified click) — its mouseUp is not ours to act on.
        guard mouseDownPoint != nil, !draggingStarted else { return }
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            onSingleClick?()
        }
    }

    /// Not handled here: AppKit walks up to the enclosing table, which is where
    /// SwiftUI installed the row context menu.
    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
    }
}
