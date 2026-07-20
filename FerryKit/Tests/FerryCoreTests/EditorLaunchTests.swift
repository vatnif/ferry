import XCTest
@testable import FerryCore

/// Unit tests for the pure editor-dispatch decision layer (M19). The actual
/// app launch (`ExternalEditorLauncher`, app target) isn't headless-testable, so
/// the branching lives here and is pinned — mirroring `TerminalDispatchTests`.
final class EditorLaunchTests: XCTestCase {

    func testDefaultUnsetResolvesToSystemDefault() {
        let dispatch = EditorDispatch.resolve(defaultEditorPath: "",
                                              override: nil,
                                              externalAllowed: true)
        XCTAssertEqual(dispatch, .launch(.systemDefault))
    }

    func testDefaultSetResolvesToThatApplication() {
        let dispatch = EditorDispatch.resolve(defaultEditorPath: "/Applications/BBEdit.app",
                                              override: nil,
                                              externalAllowed: true)
        XCTAssertEqual(dispatch, .launch(.application(path: "/Applications/BBEdit.app")))
    }

    func testOverrideWinsOverDefault() {
        let dispatch = EditorDispatch.resolve(defaultEditorPath: "/Applications/BBEdit.app",
                                              override: "/Applications/Visual Studio Code.app",
                                              externalAllowed: true)
        XCTAssertEqual(dispatch, .launch(.application(path: "/Applications/Visual Studio Code.app")))
    }

    func testBlankOverrideFallsBackToDefault() {
        let dispatch = EditorDispatch.resolve(defaultEditorPath: "/Applications/BBEdit.app",
                                              override: "   ",
                                              externalAllowed: true)
        XCTAssertEqual(dispatch, .launch(.application(path: "/Applications/BBEdit.app")))
    }

    func testWhitespaceIsTrimmed() {
        let dispatch = EditorDispatch.resolve(defaultEditorPath: "  /Applications/BBEdit.app  ",
                                              override: nil,
                                              externalAllowed: true)
        XCTAssertEqual(dispatch, .launch(.application(path: "/Applications/BBEdit.app")))
    }

    func testAppStoreBuildIsUnavailableRegardlessOfChoice() {
        for (def, override): (String, String?) in
            [("", nil), ("/Applications/BBEdit.app", nil), ("", "/Applications/Xcode.app")] {
            let dispatch = EditorDispatch.resolve(defaultEditorPath: def,
                                                  override: override,
                                                  externalAllowed: false)
            XCTAssertEqual(dispatch, .unavailable(reason: EditorDispatch.appStoreUnavailable))
        }
    }
}
