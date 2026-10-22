import XCTest

/// Launch-level UI tests for the Mac menu-bar app (`-ui-testing`: isolated state, no advertising).
final class SpatialBridgemacOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMenuBarExtraShowsStatusAndControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        let item = app.menuBars.statusItems["menubar.extra"]
        XCTAssertTrue(item.waitForExistence(timeout: 15), "menu bar item should exist")
        item.click()
        XCTAssertTrue(app.descendants(matching: .any)["menubar.available"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["menubar.chooseFolder"].exists)
        XCTAssertTrue(app.staticTexts["Choose a destination folder"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["menubar.quit"].exists)
    }
}
