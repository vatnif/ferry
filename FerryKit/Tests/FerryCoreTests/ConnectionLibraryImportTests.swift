import XCTest
@testable import FerryCore

/// Unit tests for `ConnectionLibrary.addImported` (M20 checkpoint B): the shared
/// import-merge used by the Ferry-export and competitor importers — fresh folder,
/// rebuilt hierarchy, and fresh ids (the id-collision policy).
final class ConnectionLibraryImportTests: XCTestCase {

    private func profile(_ name: String, id: UUID = UUID()) -> ConnectionProfile {
        ConnectionProfile(id: id, name: name, scheme: .sftp, host: "h", username: "me")
    }

    func testAddsUnderNewFolderAndRebuildsHierarchy() {
        var library = ConnectionLibrary()
        let entries = [
            ImportEntry(profile: profile("Top"), folderPath: []),
            ImportEntry(profile: profile("A"), folderPath: ["Work"]),
            ImportEntry(profile: profile("B"), folderPath: ["Work", "EU"]),
            ImportEntry(profile: profile("C"), folderPath: ["Work", "EU"]),
        ]
        let rootID = library.addImported(entries, intoFolderNamed: "Imported")

        let root = try! XCTUnwrap(library.folder(withID: rootID))
        XCTAssertEqual(root.name, "Imported")
        // Work folder created once and reused for its two descendants.
        let work = try! XCTUnwrap(ConnectionLibrary(items: root.items).allFolders.first { $0.name == "Work" })
        let eu = try! XCTUnwrap(ConnectionLibrary(items: work.items).allFolders.first { $0.name == "EU" })
        XCTAssertEqual(ConnectionLibrary(items: eu.items).allProfiles.map(\.name).sorted(), ["B", "C"])
        // All four profiles present under the import root.
        XCTAssertEqual(ConnectionLibrary(items: root.items).allProfiles.count, 4)
    }

    func testReidsProfilesSoImportNeverCollides() {
        // A profile whose id already exists in the library.
        let existing = profile("Existing", id: UUID())
        var library = ConnectionLibrary(items: [.profile(existing)])

        library.addImported([ImportEntry(profile: existing)], intoFolderNamed: "Imported")

        // The original is untouched and there is no duplicate id in the tree.
        XCTAssertNotNil(library.profile(withID: existing.id))
        let allIDs = library.allProfiles.map(\.id)
        XCTAssertEqual(allIDs.count, Set(allIDs).count, "an import must not create duplicate ids")
        XCTAssertEqual(library.allProfiles.filter { $0.name == "Existing" }.count, 2)
    }

    func testImportingSameEntriesTwiceProducesIndependentCopies() {
        var library = ConnectionLibrary()
        let entry = ImportEntry(profile: profile("Dup"))
        _ = library.addImported([entry], intoFolderNamed: "Imported")
        _ = library.addImported([entry], intoFolderNamed: "Imported 2")

        let ids = library.allProfiles.map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2, "each import round gets its own ids")
    }
}
