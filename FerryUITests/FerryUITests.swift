import XCTest

/// M1 smoke test: the app launches and shows the scaffold window.
/// Grows into mockup-fidelity checks from M4 (docs/TESTING.md).
final class FerryUITests: XCTestCase {
    @MainActor
    func testAppLaunchesAndShowsPlaceholder() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Ferry"].waitForExistence(timeout: 10),
                      "Placeholder window should show the app name")
    }
}
