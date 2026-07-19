import XCTest
@testable import FerryCore

/// Pure add/select/close/move rules for the tab strip (M16 checkpoint B,
/// ADR-027). Uses a trivial value element so the collection is tested in
/// isolation from the app's session types.
final class OrderedTabsTests: XCTestCase {
    private struct Tab: Identifiable, Equatable { let id: Int }

    private func make(_ ids: [Int], selected: Int? = nil) -> OrderedTabs<Tab> {
        OrderedTabs(tabs: ids.map(Tab.init(id:)), selectedID: selected)
    }

    // MARK: init / selection defaults

    func testEmptyInit() {
        let tabs = OrderedTabs<Tab>()
        XCTAssertTrue(tabs.isEmpty)
        XCTAssertNil(tabs.selectedID)
        XCTAssertNil(tabs.selected)
    }

    func testInitSelectsFirstWhenNoneGiven() {
        let tabs = make([1, 2, 3])
        XCTAssertEqual(tabs.selectedID, 1)
    }

    func testInitHonoursValidSelection() {
        let tabs = make([1, 2, 3], selected: 2)
        XCTAssertEqual(tabs.selected, Tab(id: 2))
    }

    func testInitFallsBackWhenSelectionUnknown() {
        let tabs = make([1, 2, 3], selected: 99)
        XCTAssertEqual(tabs.selectedID, 1)
    }

    // MARK: append

    func testAppendSelectsByDefault() {
        var tabs = make([1, 2])
        tabs.append(Tab(id: 3))
        XCTAssertEqual(tabs.selectedID, 3)
        XCTAssertEqual(tabs.count, 3)
    }

    func testAppendWithoutSelectKeepsSelection() {
        var tabs = make([1, 2], selected: 1)
        tabs.append(Tab(id: 3), select: false)
        XCTAssertEqual(tabs.selectedID, 1)
    }

    func testFirstAppendAlwaysSelectsEvenWhenAskedNotTo() {
        var tabs = OrderedTabs<Tab>()
        tabs.append(Tab(id: 7), select: false)
        XCTAssertEqual(tabs.selectedID, 7)
    }

    // MARK: select

    func testSelectIgnoresUnknownID() {
        var tabs = make([1, 2], selected: 1)
        tabs.select(99)
        XCTAssertEqual(tabs.selectedID, 1)
    }

    func testSelectMovesSelection() {
        var tabs = make([1, 2, 3], selected: 1)
        tabs.select(3)
        XCTAssertEqual(tabs.selectedID, 3)
    }

    // MARK: close

    func testCloseSelectedSelectsSameIndexNeighbour() {
        var tabs = make([1, 2, 3], selected: 2)
        let removed = tabs.close(2)
        XCTAssertEqual(removed, Tab(id: 2))
        // The tab that slid into index 1 (id 3) becomes selected.
        XCTAssertEqual(tabs.selectedID, 3)
        XCTAssertEqual(tabs.tabs.map(\.id), [1, 3])
    }

    func testCloseSelectedLastSelectsNewLast() {
        var tabs = make([1, 2, 3], selected: 3)
        tabs.close(3)
        XCTAssertEqual(tabs.selectedID, 2)
    }

    func testCloseNonSelectedKeepsSelection() {
        var tabs = make([1, 2, 3], selected: 2)
        tabs.close(1)
        XCTAssertEqual(tabs.selectedID, 2)
    }

    func testCloseLastRemainingClearsSelection() {
        var tabs = make([1], selected: 1)
        tabs.close(1)
        XCTAssertTrue(tabs.isEmpty)
        XCTAssertNil(tabs.selectedID)
    }

    func testCloseUnknownIDIsNoOp() {
        var tabs = make([1, 2], selected: 1)
        XCTAssertNil(tabs.close(99))
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(tabs.selectedID, 1)
    }

    // MARK: move

    func testMoveReordersAndPreservesSelection() {
        var tabs = make([1, 2, 3], selected: 2)
        tabs.move(from: 0, to: 2) // 1 goes to the end
        XCTAssertEqual(tabs.tabs.map(\.id), [2, 3, 1])
        XCTAssertEqual(tabs.selectedID, 2)
    }

    func testMoveClampsDestination() {
        var tabs = make([1, 2, 3])
        tabs.move(from: 0, to: 99)
        XCTAssertEqual(tabs.tabs.map(\.id), [2, 3, 1])
    }

    func testMoveOutOfRangeIsNoOp() {
        var tabs = make([1, 2, 3])
        tabs.move(from: 9, to: 0)
        XCTAssertEqual(tabs.tabs.map(\.id), [1, 2, 3])
    }
}
