import XCTest

/// M4 smoke tests for the connection manager. Each test runs against an
/// isolated store (FERRY_DATA_DIR → temp dir) and a test Keychain service,
/// so user data is never touched (docs/TESTING.md).
final class FerryUITests: XCTestCase {
    @MainActor
    private func launchIsolatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        let dataDir = NSTemporaryDirectory() + "ferry-uitests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        app.launchEnvironment["FERRY_DATA_DIR"] = dataDir
        app.launchEnvironment["FERRY_KEYCHAIN_SERVICE"] = "com.gfragos.Ferry.uitests"
        app.launch()
        return app
    }

    @MainActor
    func testAppLaunchesWithSidebarAndEmptyState() throws {
        let app = launchIsolatedApp()
        XCTAssertTrue(app.staticTexts["Connections"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No Connection Selected"].exists)
    }

    @MainActor
    func testNewConnectionSheetOpensAndCancels() throws {
        let app = launchIsolatedApp()
        app.buttons["sidebar.newConnection"].click()
        let nameField = app.textFields["editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["editor.test"].exists)
        app.buttons["editor.cancel"].click()
        XCTAssertFalse(nameField.waitForExistence(timeout: 2))
    }

    @MainActor
    func testCreateConnectionShowsInSidebarAndDetail() throws {
        let app = launchIsolatedApp()
        app.buttons["sidebar.newConnection"].click()

        let nameField = app.textFields["editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText("prod-web-01")
        let hostField = app.textFields["editor.host"]
        hostField.click()
        hostField.typeText("203.0.113.14")
        let userField = app.textFields["editor.username"]
        userField.click()
        userField.typeText("deploy")

        let saveButton = app.buttons["editor.save"]
        XCTAssertTrue(saveButton.isEnabled, "form with name+host+user must be savable")
        saveButton.click()

        // New profile is auto-selected: row in sidebar + summary in detail.
        XCTAssertTrue(app.staticTexts["prod-web-01"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["deploy@203.0.113.14:22"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["detail.connect"].exists)
    }
}
