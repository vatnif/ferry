import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Ferry's private drag type, declared in `Ferry/Info.plist`
    /// (`UTExportedTypeDeclarations`). The declaration is load-bearing:
    /// SwiftUI's drop machinery cannot match an undeclared identifier
    /// (measured — it decodes zero items), which is why ADR-038 adds a real
    /// Info.plist to this otherwise fully-generated target.
    static let ferryDragItem = UTType(exportedAs: RemoteDragPayload.typeIdentifier)
}

/// The M8 inter-pane drag payload (`ferryitem|<kind>|<d/f>|<path>`), carried
/// on the same pasteboard item as the remote row's file promise. AppKit writes
/// it as raw UTF-8 (`RemoteDragBridge`); the pane's `.dropDestination`
/// decodes it through this `Transferable`.
struct RemoteDragPayload: Transferable {
    static let typeIdentifier = "com.gfragos.ferry.drag-item"

    let value: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .ferryDragItem) { payload in
            Data(payload.value.utf8)
        } importing: { data in
            RemoteDragPayload(value: String(decoding: data, as: UTF8.self))
        }
    }
}
