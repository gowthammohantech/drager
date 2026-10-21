import XCTest

/// Launch-level UI tests for the iPhone app. Feature flows are added per phase.
final class SpatialBridgeiOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesToRoot() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Spatial Bridge"].waitForExistence(timeout: 10))
    }
}
