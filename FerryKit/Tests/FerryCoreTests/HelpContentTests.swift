import XCTest
@testable import FerryCore

/// Unit tests for the in-app help + acknowledgements content (M16 checkpoint C,
/// ADR-028). These pin the *integrity* of the pure content models — the SwiftUI
/// windows only render them — so a dropped copyright line or a forbidden license
/// fails the build rather than shipping.
final class HelpContentTests: XCTestCase {

    // MARK: Acknowledgements

    func testAcknowledgementsCoverLicensingInventory() {
        let names = Set(Acknowledgements.all.map(\.name))
        // The shipped dependencies LICENSING.md requires on the notice screen.
        for required in ["Citadel", "swift-nio-ssh", "swift-crypto", "SwiftTerm", "libcurl", "Apple SDKs"] {
            XCTAssertTrue(names.contains(required), "Acknowledgements is missing \(required)")
        }
    }

    func testEveryAcknowledgementIsComplete() {
        XCTAssertFalse(Acknowledgements.all.isEmpty)
        for ack in Acknowledgements.all {
            XCTAssertFalse(ack.name.trimmingCharacters(in: .whitespaces).isEmpty, "empty name")
            XCTAssertFalse(ack.purpose.trimmingCharacters(in: .whitespaces).isEmpty, "\(ack.name): empty purpose")
            XCTAssertFalse(ack.copyright.trimmingCharacters(in: .whitespaces).isEmpty, "\(ack.name): empty copyright")
            XCTAssertFalse(ack.license.body.trimmingCharacters(in: .whitespaces).isEmpty, "\(ack.name): empty license body")
        }
    }

    func testEveryLicenseIsCommerciallyRedistributable() {
        // CLAUDE.md rule 4: no GPL/LGPL/AGPL/SSPL etc. may ever appear here.
        for ack in Acknowledgements.all {
            XCTAssertTrue(ack.license.isCommerciallyRedistributable,
                          "\(ack.name) ships under a forbidden license: \(ack.license.rawValue)")
        }
        for license in DependencyLicense.allCases {
            XCTAssertTrue(license.isCommerciallyRedistributable)
        }
    }

    func testAcknowledgementNamesAreUnique() {
        let names = Acknowledgements.all.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "duplicate acknowledgement name")
        // `id` is the name, so identity is stable for SwiftUI ForEach.
        XCTAssertEqual(Acknowledgements.all.map(\.id), names)
    }

    // MARK: Help content

    func testShortcutsAreCompleteAndUnique() {
        XCTAssertFalse(HelpContent.shortcuts.isEmpty)
        for shortcut in HelpContent.shortcuts {
            XCTAssertFalse(shortcut.keys.trimmingCharacters(in: .whitespaces).isEmpty, "empty keys")
            XCTAssertFalse(shortcut.action.trimmingCharacters(in: .whitespaces).isEmpty, "empty action")
        }
        let ids = HelpContent.shortcuts.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate shortcut")
    }

    func testShortcutsIncludeTabAffordances() {
        // The M16 checkpoint-B additions must be documented (prompt requirement).
        let keys = HelpContent.shortcuts.map(\.keys)
        XCTAssertTrue(keys.contains("⌘T"))
        XCTAssertTrue(keys.contains("⌘W"))
        XCTAssertTrue(keys.contains("⌘⇧I"))
        XCTAssertTrue(keys.contains(where: { $0.contains("double-click") }))
    }

    func testTopicsIncludeEditorRoundTrip() {
        // M19: the editor round-trip is a user-facing feature and must stay
        // documented (the user mandated updating Help for any new feature).
        let topic = HelpContent.topics.first {
            $0.body.contains("Open in Editor") || $0.title.contains("Editing")
        }
        XCTAssertNotNil(topic, "no topic documents the editor round-trip")
        XCTAssertTrue(HelpContent.shortcuts.contains { $0.keys == "⌘E" },
                      "the Open in Editor shortcut should be listed")
    }

    func testTopicsDocumentCompetitorImport() {
        // M20 checkpoint A: the FileZilla/Cyberduck/WinSCP importers are
        // user-facing and must stay documented (the user mandated updating Help
        // for any new feature), including the WinSCP .ppk-key caveat.
        let topic = HelpContent.topics.first { $0.title == "Importing connections" }
        let body = try? XCTUnwrap(topic).body
        XCTAssertNotNil(topic, "no topic documents importing connections")
        for source in ["FileZilla", "Cyberduck", "WinSCP"] {
            XCTAssertTrue(body?.contains(source) ?? false, "import topic omits \(source)")
        }
        XCTAssertTrue(body?.contains(".ppk") ?? false, "import topic omits the WinSCP key caveat")
    }

    func testTopicsDocumentExportImport() {
        // M20 checkpoint B: Ferry's own export/import is user-facing and must
        // stay documented, including that exports carry no passwords.
        let body = HelpContent.topics.first { $0.title == "Importing connections" }?.body ?? ""
        XCTAssertTrue(body.contains("Export"), "import topic omits export")
        XCTAssertTrue(body.contains("From Ferry Export"), "import topic omits Ferry-export import")
        XCTAssertTrue(body.lowercased().contains("no password"), "must state exports carry no passwords")
    }

    func testTopicsIncludeResumeExplainer() {
        XCTAssertFalse(HelpContent.topics.isEmpty)
        for topic in HelpContent.topics {
            XCTAssertFalse(topic.title.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(topic.body.trimmingCharacters(in: .whitespaces).isEmpty, "\(topic.title): empty body")
        }
        // The .ferrypart/resume explainer is a named ROADMAP.md M16 deliverable.
        let resumeTopic = HelpContent.topics.first { $0.body.contains(".ferrypart") }
        XCTAssertNotNil(resumeTopic, "no topic explains the .ferrypart resume behaviour")
        let ids = HelpContent.topics.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate topic title")
    }
}
