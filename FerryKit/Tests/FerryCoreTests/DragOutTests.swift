import XCTest
@testable import FerryCore

/// M21 checkpoint B: the pure decision layer behind a remote→Finder drag —
/// `DragOutPlan` (the promise's transfer request + litter cleanup) and
/// `DragOutPolicy` (Finder's what-gets-dragged selection semantics).
/// Uses the InMemoryFileSource stub from TransferEngineTests.swift.
final class DragOutTests: XCTestCase {
    private let source = InMemoryFileSource()

    private func filePlan(destinationExisted: Bool = false,
                          destination: InMemoryFileSource = InMemoryFileSource(),
                          groupID: UUID = UUID()) -> DragOutPlan {
        DragOutPlan.make(item: FileItem(name: "report.pdf", path: "/remote/docs/report.pdf",
                                        isDirectory: false, size: 1234),
                         destinationPath: "/Users/me/Downloads/report.pdf",
                         source: source, destination: destination,
                         destinationExisted: destinationExisted, groupID: groupID)
    }

    private func directoryPlan(destinationExisted: Bool,
                               destination: InMemoryFileSource = InMemoryFileSource(),
                               groupID: UUID = UUID()) -> DragOutPlan {
        DragOutPlan.make(item: FileItem(name: "logs", path: "/remote/logs", isDirectory: true),
                         destinationPath: "/Users/me/Downloads/logs",
                         source: source, destination: destination,
                         destinationExisted: destinationExisted, groupID: groupID)
    }

    // MARK: 13 — make

    func testMakeAlwaysRestartsWithExactDestinationAndGroup() {
        let group = UUID()
        let plan = filePlan(groupID: group)
        XCTAssertEqual(plan.request.mode, .restart,
                       "a drag must never resume a stranger's .ferrypart at the drop location")
        XCTAssertEqual(plan.request.direction, .download)
        XCTAssertEqual(plan.request.kind, .file)
        XCTAssertEqual(plan.request.groupID, group)
        XCTAssertEqual(plan.request.sourcePath, "/remote/docs/report.pdf")
        XCTAssertEqual(plan.request.destinationPath, "/Users/me/Downloads/report.pdf")
        XCTAssertEqual(plan.request.displayName, "report.pdf")
        XCTAssertEqual(plan.partialPath,
                       "/Users/me/Downloads/report.pdf" + TransferEngine.partialSuffix)

        let folder = directoryPlan(destinationExisted: false, groupID: group)
        XCTAssertEqual(folder.request.kind, .directory)
        XCTAssertEqual(folder.request.mode, .restart)
        XCTAssertEqual(folder.request.groupID, group)
        XCTAssertEqual(folder.request.destinationPath, "/Users/me/Downloads/logs")
    }

    // MARK: 14 — litter

    func testLitterAcrossOutcomesKindsAndPreexistence() {
        let outcomes: [TransferGroupOutcome] = [.failed("boom"), .cancelled]

        for existed in [false, true] {
            let plan = filePlan(destinationExisted: existed)
            XCTAssertEqual(plan.litter(after: .completed), [])
            for outcome in outcomes {
                XCTAssertEqual(plan.litter(after: outcome), [plan.partialPath],
                               "a file's litter is only its partial — Finder owns the destination URL")
            }
        }

        let created = directoryPlan(destinationExisted: false)
        XCTAssertEqual(created.litter(after: .completed), [])
        for outcome in outcomes {
            XCTAssertEqual(created.litter(after: outcome), ["/Users/me/Downloads/logs"],
                           "a directory we created is removed whole")
        }

        let preexisting = directoryPlan(destinationExisted: true)
        for outcome in outcomes {
            XCTAssertEqual(preexisting.litter(after: outcome), [],
                           "never delete a directory that was already there")
        }
        XCTAssertEqual(preexisting.litter(after: .completed), [])
    }

    // MARK: 15 — cleanUp

    func testCleanUpRemovesLitterAndIsIdempotent() async {
        let destination = InMemoryFileSource(
            files: ["/Users/me/Downloads/report.pdf" + TransferEngine.partialSuffix:
                        Data(repeating: 1, count: 10),
                    "/Users/me/Downloads/report.pdf": Data(repeating: 2, count: 10)])
        let plan = filePlan(destination: destination)

        await plan.cleanUp(after: .cancelled)
        XCTAssertNil(destination.data(at: plan.partialPath))
        XCTAssertNotNil(destination.data(at: "/Users/me/Downloads/report.pdf"),
                        "the destination path itself is never a file plan's litter")
        // Already gone: a second pass must be a silent no-op.
        await plan.cleanUp(after: .cancelled)
        XCTAssertNil(destination.data(at: plan.partialPath))

        // A directory the drag created goes whole, nested partials included.
        let treeDestination = InMemoryFileSource(
            files: ["/Users/me/Downloads/logs/x.log" + TransferEngine.partialSuffix:
                        Data(repeating: 3, count: 10)],
            directories: ["/Users/me/Downloads/logs"])
        let created = directoryPlan(destinationExisted: false, destination: treeDestination)
        await created.cleanUp(after: .failed("boom"))
        XCTAssertFalse(treeDestination.hasDirectory("/Users/me/Downloads/logs"))
        XCTAssertNil(treeDestination.data(
            at: "/Users/me/Downloads/logs/x.log" + TransferEngine.partialSuffix))

        // A pre-existing directory is left alone.
        let guardedDestination = InMemoryFileSource(directories: ["/Users/me/Downloads/logs"])
        let preexisting = directoryPlan(destinationExisted: true, destination: guardedDestination)
        await preexisting.cleanUp(after: .cancelled)
        XCTAssertTrue(guardedDestination.hasDirectory("/Users/me/Downloads/logs"))
    }

    // MARK: 16 — what a drag takes with it

    func testItemsToDragFollowsFinderSelectionSemantics() {
        let items = [FileItem(name: "a.txt", path: "/r/a.txt", isDirectory: false),
                     FileItem(name: "b.txt", path: "/r/b.txt", isDirectory: false),
                     FileItem(name: "c.txt", path: "/r/c.txt", isDirectory: false)]

        // Clicked inside the selection: the whole selection, in listing order.
        let selected = DragOutPolicy.itemsToDrag(clicked: items[2],
                                                 selection: ["/r/c.txt", "/r/a.txt"],
                                                 in: items)
        XCTAssertEqual(selected.map(\.path), ["/r/a.txt", "/r/c.txt"])

        // Clicked outside the selection: only that row.
        let outside = DragOutPolicy.itemsToDrag(clicked: items[1],
                                                selection: ["/r/a.txt", "/r/c.txt"],
                                                in: items)
        XCTAssertEqual(outside.map(\.path), ["/r/b.txt"])

        // Empty selection: only the clicked row.
        let none = DragOutPolicy.itemsToDrag(clicked: items[0], selection: [], in: items)
        XCTAssertEqual(none.map(\.path), ["/r/a.txt"])

        // Stale ids (rows gone after a reload) drop out of the drag.
        let stale = DragOutPolicy.itemsToDrag(clicked: items[0],
                                              selection: ["/r/a.txt", "/r/deleted.txt"],
                                              in: items)
        XCTAssertEqual(stale.map(\.path), ["/r/a.txt"])
    }
}
