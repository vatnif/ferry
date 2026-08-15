import Foundation

/// One promised item of a remote→Finder drag-out: the transfer request that
/// fulfils the promise plus the cleanup knowledge the promise callback needs
/// when the group ends any way other than completed.
public struct DragOutPlan: Sendable {
    public let request: TransferRequest
    /// True when the drop path already existed. A folder drag may remove the
    /// tree it created; it must never delete a directory that was already
    /// there — we cannot tell our bytes from the user's.
    public let destinationExisted: Bool

    public var partialPath: String { request.destinationPath + TransferEngine.partialSuffix }

    /// Always `.restart`: the engine's resume heuristic would silently append
    /// to any fresh, similar-sized `.ferrypart` left at the drop location by
    /// an earlier drag of a *different* file, and a drag has no conflict
    /// prompt to reason about it. `.restart` truncates the partial away, and
    /// children inherit the mode, so a whole dropped tree restarts.
    public static func make(item: FileItem, destinationPath: String,
                            source: any FileSystemSource, destination: any FileSystemSource,
                            destinationExisted: Bool, groupID: UUID) -> DragOutPlan {
        DragOutPlan(request: TransferRequest(direction: .download,
                                             kind: item.isDirectory ? .directory : .file,
                                             mode: .restart,
                                             groupID: groupID,
                                             source: source, sourcePath: item.path,
                                             destination: destination,
                                             destinationPath: destinationPath,
                                             displayName: item.name),
                    destinationExisted: destinationExisted)
    }

    /// Paths to remove for `outcome` — empty on `.completed`. For a file only
    /// the `.ferrypart` is ours; the destination URL itself belongs to Finder.
    /// A directory we created is removed whole (a recursive delete takes
    /// nested `.ferrypart`s with it); a pre-existing one is left alone.
    public func litter(after outcome: TransferGroupOutcome) -> [String] {
        if case .completed = outcome { return [] }
        switch request.kind {
        case .file:
            return [partialPath]
        case .directory:
            return destinationExisted ? [] : [request.destinationPath]
        }
    }

    /// Best-effort removal of `litter(after:)`; a path already gone is fine.
    /// Run this only on `.finished`, never on `.stalled` — a paused drag
    /// keeps its partial data so Resume can still land the file.
    public func cleanUp(after outcome: TransferGroupOutcome) async {
        for path in litter(after: outcome) {
            try? await request.destination.delete(at: path)
        }
    }
}

public enum DragOutPolicy {
    /// Finder semantics: dragging a row inside the selection drags the whole
    /// selection in listing order; an unselected row drags only itself.
    /// Selection ids with no matching row (stale after a reload) drop out.
    public static func itemsToDrag(clicked: FileItem, selection: Set<String>,
                                   in items: [FileItem]) -> [FileItem] {
        guard selection.contains(clicked.id) else { return [clicked] }
        let selected = items.filter { selection.contains($0.id) }
        return selected.isEmpty ? [clicked] : selected
    }
}
