import XCTest

/// Launch-level UI tests for the Mac menu-bar app.
final class SpatialBridgemacOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMenuBarExtraAppears() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing"]
        app.launch()
        // LSUIElement apps have no Dock icon; the status item is the only UI.
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), "menu bar extra should exist")
        statusItem.click()
        XCTAssertTrue(app.staticTexts["Spatial Bridge"].waitForExistence(timeout: 5))
    }
}
