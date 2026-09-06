import XCTest
@testable import FerryCore

/// Batch-level dock header summary: a completed-of-total **file count** and a
/// **byte-weighted** overall bar. Directory rows only enumerate children, so
/// they never count as files but keep the bar indeterminate while running.
final class QueueBatchSummaryTests: XCTestCase {

    private func file(_ phase: TransferSnapshot.Phase,
                      transferred: Int64 = 0,
                      total: Int64? = nil) -> QueueBatchItem {
        QueueBatchItem(kind: .file, phase: phase, bytesTransferred: transferred, totalBytes: total)
    }

    private func dir(_ phase: TransferSnapshot.Phase) -> QueueBatchItem {
        QueueBatchItem(kind: .directory, phase: phase, bytesTransferred: 0, totalBytes: nil)
    }

    // MARK: - Counts

    func testCountsOnlyFilesNotDirectories() {
        let summary = QueueBatch.summarize([
            dir(.completed),                       // container — not a file
            file(.completed, transferred: 10, total: 10),
            file(.running, transferred: 5, total: 20),
            file(.queued, total: 30),
        ])
        XCTAssertEqual(summary.completedFiles, 1)
        XCTAssertEqual(summary.totalFiles, 3)
        XCTAssertTrue(summary.showsSummary)
    }

    func testFailedAndCancelledStayInTotalButNotCompleted() {
        let summary = QueueBatch.summarize([
            file(.completed, transferred: 10, total: 10),
            file(.failed("boom"), transferred: 3, total: 10),
            file(.cancelled, transferred: 1, total: 10),
        ])
        XCTAssertEqual(summary.completedFiles, 1)
        XCTAssertEqual(summary.totalFiles, 3)
    }

    func testSingleFileDoesNotShowSummary() {
        let summary = QueueBatch.summarize([file(.running, transferred: 5, total: 10)])
        XCTAssertFalse(summary.showsSummary)
        XCTAssertEqual(summary.bar, .hidden)
    }

    // MARK: - Byte-weighted bar

    func testBarIsByteWeightedNotFileCount() {
        // Nine tiny files done + one huge file barely started: a count-based
        // bar would read ~90%; the byte-weighted bar must read near zero.
        var items = (0..<9).map { _ in file(.completed, transferred: 1, total: 1) }
        items.append(file(.running, transferred: 0, total: 1_000_000))
        guard case .fraction(let value) = QueueBatch.summarize(items).bar else {
            return XCTFail("expected a determinate fraction")
        }
        XCTAssertLessThan(value, 0.01)
    }

    func testBarSumsTransferredOverTotal() {
        let summary = QueueBatch.summarize([
            file(.completed, transferred: 100, total: 100),
            file(.running, transferred: 50, total: 100),
        ])
        XCTAssertEqual(summary.bar, .fraction(0.75))
    }

    func testBarIndeterminateWhileDirectoryEnumerating() {
        let summary = QueueBatch.summarize([
            dir(.running),                         // still adding children
            file(.completed, transferred: 100, total: 100),
            file(.running, transferred: 50, total: 100),
        ])
        XCTAssertEqual(summary.bar, .indeterminate)
    }

    func testBarIndeterminateWhenRunningFileSizeUnknown() {
        let summary = QueueBatch.summarize([
            file(.completed, transferred: 100, total: 100),
            file(.running, transferred: 50, total: nil),   // size not yet known
        ])
        XCTAssertEqual(summary.bar, .indeterminate)
    }

    func testFinishedDirectoryDoesNotForceIndeterminate() {
        let summary = QueueBatch.summarize([
            dir(.completed),
            file(.completed, transferred: 100, total: 100),
            file(.running, transferred: 25, total: 100),
        ])
        XCTAssertEqual(summary.bar, .fraction(0.625))
    }

    func testBarHiddenWhenAllFilesFinished() {
        let summary = QueueBatch.summarize([
            file(.completed, transferred: 100, total: 100),
            file(.completed, transferred: 200, total: 200),
        ])
        XCTAssertEqual(summary.bar, .hidden)
        // ...but the count text still reports the finished batch.
        XCTAssertTrue(summary.showsSummary)
        XCTAssertEqual(summary.completedFiles, 2)
        XCTAssertEqual(summary.totalFiles, 2)
    }

    func testBarNeverExceedsOne() {
        // A defensive clamp: bytesTransferred should never exceed totalBytes,
        // but if a snapshot briefly overshoots the bar must still cap at 1.
        let summary = QueueBatch.summarize([
            file(.running, transferred: 150, total: 100),
            file(.running, transferred: 100, total: 100),
        ])
        XCTAssertEqual(summary.bar, .fraction(1))
    }

    func testEmptyQueueIsHiddenAndEmpty() {
        let summary = QueueBatch.summarize([])
        XCTAssertEqual(summary.completedFiles, 0)
        XCTAssertEqual(summary.totalFiles, 0)
        XCTAssertEqual(summary.bar, .hidden)
        XCTAssertFalse(summary.showsSummary)
    }
}
