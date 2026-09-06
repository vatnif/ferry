import Foundation

/// Batch-level view of the transfer queue for the dock header: a
/// completed-of-total **file count** plus a **byte-weighted** overall
/// progress bar. Directory rows only enumerate their children onto the
/// queue, so they never count as "files" — but an unfinished directory
/// means more bytes are still coming, which forces the bar indeterminate.
///
/// Pure and `Sendable` so it is unit-tested in FerryKit; the app's
/// `TransferQueueModel` maps its rows to `Item`s and renders the result.
public struct QueueBatchSummary: Equatable, Sendable {
    /// The overall progress bar's state.
    public enum Bar: Equatable, Sendable {
        /// No bar: nothing in flight (fewer than two files, or all finished).
        case hidden
        /// Work is in flight but the total size isn't settled yet — a folder
        /// is still enumerating, or a running file's size is unknown.
        case indeterminate
        /// A settled fraction in 0...1 of total bytes transferred.
        case fraction(Double)
    }

    /// File rows that reached `.completed`.
    public let completedFiles: Int
    /// All file rows in the batch (includes failed/cancelled — they were
    /// part of the batch and simply never completed).
    public let totalFiles: Int
    public let bar: Bar

    /// The header only shows a batch summary when more than one file is
    /// involved; a lone file is fully described by its own row.
    public var showsSummary: Bool { totalFiles > 1 }
}

/// One queue row reduced to just what the batch summary needs.
public struct QueueBatchItem: Sendable {
    public let kind: TransferRequest.Kind
    public let phase: TransferSnapshot.Phase
    public let bytesTransferred: Int64
    public let totalBytes: Int64?

    public init(kind: TransferRequest.Kind,
                phase: TransferSnapshot.Phase,
                bytesTransferred: Int64,
                totalBytes: Int64?) {
        self.kind = kind
        self.phase = phase
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }
}

public enum QueueBatch {
    /// Reduce the current queue rows to a batch summary.
    public static func summarize(_ items: [QueueBatchItem]) -> QueueBatchSummary {
        let files = items.filter { $0.kind == .file }
        let completed = files.filter { $0.phase == .completed }.count

        return QueueBatchSummary(completedFiles: completed,
                                 totalFiles: files.count,
                                 bar: bar(files: files, items: items))
    }

    private static func bar(files: [QueueBatchItem], items: [QueueBatchItem]) -> QueueBatchSummary.Bar {
        // Nothing to summarise, or the whole batch has come to rest.
        guard files.count > 1 else { return .hidden }
        if files.allSatisfy({ $0.phase.isFinished }) { return .hidden }

        // A folder still enumerating will add more bytes; a still-running file
        // of unknown size can't be weighted. Either way the total isn't settled.
        let enumerating = items.contains { $0.kind == .directory && !$0.phase.isFinished }
        let unknownSize = files.contains { $0.totalBytes == nil && !$0.phase.isFinished }
        if enumerating || unknownSize { return .indeterminate }

        var total: Int64 = 0
        var transferred: Int64 = 0
        for file in files {
            guard let size = file.totalBytes else { continue }
            total += size
            transferred += min(file.bytesTransferred, size)
        }
        guard total > 0 else { return .indeterminate }
        return .fraction(min(1, Double(transferred) / Double(total)))
    }
}
