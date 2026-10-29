import XCTest

/// Captures App Store screenshots with seeded, offline state (`-screenshots`).
/// Skipped unless `SCREENSHOT_DIR` is set; pass it as `TEST_RUNNER_SCREENSHOT_DIR`.
final class AppStoreScreenshots: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else {
            throw XCTSkip("SCREENSHOT_DIR not set")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-screenshots"] + extra
        app.launch()
        return app
    }

    private func snap(_ name: String) throws {
        sleep(1)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    func testCaptureScreenshots() throws {
        var app = launch(["-skip-onboarding"])
        XCTAssertTrue(app.descendants(matching: .any)["home.throwSurface"].waitForExistence(timeout: 10))
        try snap("01-throw")

        app.tabBars.buttons["History"].tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Lisbon tram'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        try snap("04-history")

        app.tabBars.buttons["Settings"].tap()
        app.buttons["Calibration"].tap()
        XCTAssertTrue(app.navigationBars["Calibration"].waitForExistence(timeout: 5))
        try snap("03-calibration")

        app.terminate()
        app = launch(["-skip-onboarding", "-screenshot-transfer"])
        XCTAssertTrue(app.descendants(matching: .any)["home.throwSurface"].waitForExistence(timeout: 10))
        try snap("02-saved")

        app.terminate()
        app = launch([])
        XCTAssertTrue(app.buttons["onboarding.start"].waitForExistence(timeout: 10))
        try snap("05-welcome")
    }
}
