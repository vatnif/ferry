import XCTest
@testable import FerryCore

final class FilePermissionsTests: XCTestCase {
    func testSymbolicRendering() {
        XCTAssertEqual(FilePermissions(rawMode: 0o755).symbolic, "rwxr-xr-x")
        XCTAssertEqual(FilePermissions(rawMode: 0o644).symbolic, "rw-r--r--")
        XCTAssertEqual(FilePermissions(rawMode: 0o000).symbolic, "---------")
        XCTAssertEqual(FilePermissions(rawMode: 0o777).symbolic, "rwxrwxrwx")
        XCTAssertEqual(FilePermissions(rawMode: 0o640).symbolic, "rw-r-----")
    }

    func testOctalRoundTrip() {
        for octal in ["755", "644", "700", "777", "0"] {
            let permissions = FilePermissions(octalString: octal)
            XCTAssertNotNil(permissions, octal)
            XCTAssertEqual(FilePermissions(octalString: permissions!.octalString), permissions)
        }
        XCTAssertEqual(FilePermissions(octalString: "755")?.rawMode, 0o755)
    }

    func testInvalidOctalRejected() {
        XCTAssertNil(FilePermissions(octalString: "999"))
        XCTAssertNil(FilePermissions(octalString: "abc"))
        XCTAssertNil(FilePermissions(octalString: "10000"))
        XCTAssertNil(FilePermissions(octalString: ""))
    }

    func testRawModeMasksToPermissionBits() {
        // File-type bits (e.g. S_IFREG 0o100000) must not leak in.
        XCTAssertEqual(FilePermissions(rawMode: 0o100644).rawMode, 0o644)
    }
}
