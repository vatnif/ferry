import XCTest
@testable import FerryCore

final class ConnectionLibraryTests: XCTestCase {

    // MARK: Queries

    func testAllProfilesFlattensDepthFirstInDisplayOrder() {
        let f = TestFixtures.library()
        XCTAssertEqual(f.library.allProfiles.map(\.name),
                       ["prod-web-01", "staging", "db-bastion", "pi-home"])
    }

    func testLookupsFindNestedItems() {
        let f = TestFixtures.library()
        XCTAssertEqual(f.library.profile(withID: f.bastion.id)?.name, "db-bastion")
        XCTAssertEqual(f.library.folder(withID: f.acme.id)?.name, "acme")
        XCTAssertTrue(f.library.contains(itemID: f.pi.id))
        XCTAssertNil(f.library.profile(withID: UUID()))
        XCTAssertNil(f.library.folder(withID: UUID()))
    }

    // MARK: Add / remove / update

    func testAddToRootAndToNestedFolder() {
        var f = TestFixtures.library()
        let new = TestFixtures.profile(name: "new-server")

        XCTAssertTrue(f.library.add(.profile(new), toFolder: f.acme.id))
        XCTAssertEqual(f.library.folder(withID: f.acme.id)?.items.map(\.name),
                       ["db-bastion", "new-server"])

        let loose = TestFixtures.profile(name: "loose")
        XCTAssertTrue(f.library.add(.profile(loose), at: 0))
        XCTAssertEqual(f.library.items.first?.name, "loose")

        XCTAssertFalse(f.library.add(.profile(new), toFolder: UUID()),
                       "adding to a nonexistent folder must fail")
    }

    func testRemoveProfileAndWholeFolderSubtree() {
        var f = TestFixtures.library()

        let removed = f.library.removeItem(withID: f.staging.id)
        XCTAssertEqual(removed?.name, "staging")

        // Removing Clients also removes nested acme/db-bastion.
        XCTAssertNotNil(f.library.removeItem(withID: f.clients.id))
        XCTAssertEqual(f.library.allProfiles.map(\.name), ["prod-web-01", "pi-home"])

        XCTAssertNil(f.library.removeItem(withID: UUID()))
    }

    func testUpdateProfileInPlaceBumpsModifiedAt() {
        var f = TestFixtures.library()
        var changed = f.bastion
        changed.host = "bastion.acme.internal"

        XCTAssertTrue(f.library.updateProfile(changed))
        let reloaded = f.library.profile(withID: f.bastion.id)
        XCTAssertEqual(reloaded?.host, "bastion.acme.internal")
        XCTAssertEqual(f.library.folder(withID: f.acme.id)?.items.first?.id, f.bastion.id,
                       "update must not move the profile")
        XCTAssertGreaterThan(reloaded!.modifiedAt, TestFixtures.date)

        XCTAssertFalse(f.library.updateProfile(TestFixtures.profile(name: "ghost")))
    }

    func testFolderRenameAndExpansionState() {
        var f = TestFixtures.library()
        XCTAssertTrue(f.library.renameFolder(withID: f.acme.id, to: "ACME Corp"))
        XCTAssertEqual(f.library.folder(withID: f.acme.id)?.name, "ACME Corp")
        XCTAssertTrue(f.library.setFolderExpanded(withID: f.work.id, false))
        XCTAssertEqual(f.library.folder(withID: f.work.id)?.isExpanded, false)
        XCTAssertFalse(f.library.renameFolder(withID: UUID(), to: "x"))
    }

    // MARK: Move

    func testMoveProfileBetweenFoldersAndToRoot() {
        var f = TestFixtures.library()

        XCTAssertTrue(f.library.move(itemID: f.prod.id, toFolder: f.acme.id, at: 0))
        XCTAssertEqual(f.library.folder(withID: f.acme.id)?.items.map(\.name),
                       ["prod-web-01", "db-bastion"])

        XCTAssertTrue(f.library.move(itemID: f.prod.id, toFolder: nil, at: 0))
        XCTAssertEqual(f.library.items.first?.name, "prod-web-01")
        XCTAssertEqual(f.library.allProfiles.count, 4, "move must never lose profiles")
    }

    func testMoveFolderIntoItselfOrDescendantIsRefused() {
        var f = TestFixtures.library()
        let before = f.library

        XCTAssertFalse(f.library.move(itemID: f.clients.id, toFolder: f.clients.id))
        XCTAssertFalse(f.library.move(itemID: f.clients.id, toFolder: f.acme.id),
                       "acme is inside Clients — cycle must be refused")
        XCTAssertEqual(f.library, before, "failed move must leave the library unchanged")

        // Sanity: a legal folder move still works.
        XCTAssertTrue(f.library.move(itemID: f.acme.id, toFolder: f.work.id))
        XCTAssertEqual(f.library.folder(withID: f.work.id)?.items.map(\.name),
                       ["prod-web-01", "staging", "acme"])
    }

    // MARK: Codable

    func testLibraryCodableRoundTripPreservesTreeExactly() throws {
        let f = TestFixtures.library()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ConnectionLibrary.self,
                                         from: try encoder.encode(f.library))
        XCTAssertEqual(decoded, f.library)
    }

    func testSidebarItemJSONUsesCleanDiscriminator() throws {
        // The on-disk shape is a contract (schemaVersion 1) — this test
        // pins it so accidental Codable changes fail loudly.
        let item = SidebarItem.folder(ProfileFolder(name: "Work"))
        let json = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        XCTAssertTrue(json.contains(#""type":"folder""#), "unexpected schema: \(json)")
        XCTAssertFalse(json.contains("_0"), "synthesized enum encoding leaked into the schema")
    }
}
