import XCTest
@testable import FerryCore

final class FerryVersionTests: XCTestCase {
    func testVersionIsValidSemver() throws {
        let components = try XCTUnwrap(FerryVersion.components,
                                       "FerryVersion.current must be MAJOR.MINOR.PATCH")
        XCTAssertGreaterThanOrEqual(components.major, 0)
    }
}
