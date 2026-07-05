import XCTest
@testable import FerryCore

/// M4 additions: parent lookup + folder enumeration (feed the sidebar's
/// "Move to" menu and the editor's folder picker).
final class ConnectionLibraryHierarchyTests: XCTestCase {
    func testParentFolderIDResolvesAtEveryDepth() {
        let f = TestFixtures.library()
        XCTAssertNil(f.library.parentFolderID(ofItem: f.pi.id), "loose profile is at root")
        XCTAssertNil(f.library.parentFolderID(ofItem: f.work.id), "top-level folder is at root")
        XCTAssertEqual(f.library.parentFolderID(ofItem: f.prod.id), f.work.id)
        XCTAssertEqual(f.library.parentFolderID(ofItem: f.acme.id), f.clients.id)
        XCTAssertEqual(f.library.parentFolderID(ofItem: f.bastion.id), f.acme.id)
        XCTAssertNil(f.library.parentFolderID(ofItem: UUID()), "unknown id has no parent")
    }

    func testAllFoldersDepthFirstDisplayOrder() {
        let f = TestFixtures.library()
        XCTAssertEqual(f.library.allFolders.map(\.name), ["Work", "Clients", "acme"])
    }
}
