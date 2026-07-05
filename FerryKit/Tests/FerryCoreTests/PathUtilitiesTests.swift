import XCTest
@testable import FerryCore

/// M7: the sync-browsing mirroring contract (DESIGN.md screen 1) rests on
/// these two helpers.
final class PathUtilitiesTests: XCTestCase {
    func testRelativePathUnderAnchor() {
        XCTAssertEqual(PathUtilities.relativePath(of: "/var/www/html", under: "/var/www"), "html")
        XCTAssertEqual(PathUtilities.relativePath(of: "/var/www/a/b", under: "/var/www"), "a/b")
        XCTAssertEqual(PathUtilities.relativePath(of: "/var/www", under: "/var/www"), "")
        XCTAssertEqual(PathUtilities.relativePath(of: "/a/b", under: "/"), "a/b")
    }

    func testRelativePathOutsideAnchorIsNil() {
        XCTAssertNil(PathUtilities.relativePath(of: "/etc/hosts", under: "/var/www"))
        XCTAssertNil(PathUtilities.relativePath(of: "/var/wwwx/site", under: "/var/www"),
                     "prefix match must respect path component boundaries")
        XCTAssertNil(PathUtilities.relativePath(of: "/var", under: "/var/www"))
    }

    func testJoin() {
        XCTAssertEqual(PathUtilities.join("/var/www", "html"), "/var/www/html")
        XCTAssertEqual(PathUtilities.join("/", "home"), "/home")
        XCTAssertEqual(PathUtilities.join("/a/", "b/c"), "/a/b/c")
        XCTAssertEqual(PathUtilities.join("/a", ""), "/a")
    }

    func testMirrorComposition() {
        // The exact computation BrowserSession performs when panes are linked.
        let localAnchor = "/Users/me/site", remoteAnchor = "/var/www/html"
        let navigatedTo = "/Users/me/site/assets/img"
        let relative = PathUtilities.relativePath(of: navigatedTo, under: localAnchor)!
        XCTAssertEqual(PathUtilities.join(remoteAnchor, relative), "/var/www/html/assets/img")
    }
}
