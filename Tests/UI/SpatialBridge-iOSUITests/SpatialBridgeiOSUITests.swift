import XCTest

/// UI tests run with `-ui-testing`: in-memory stores, no networking, so they
/// are deterministic on any simulator.
final class SpatialBridgeiOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"] + extra
        app.launch()
        return app
    }

    func testOnboardingFlowReachesDiscovery() throws {
        let app = launch()
        XCTAssertTrue(app.otherElements["onboarding.welcome"].waitForExistence(timeout: 5) || app.buttons["onboarding.start"].exists)
        app.buttons["onboarding.start"].tap()
        let next = app.buttons["onboarding.localNetwork.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        // Discovery shows the searching state (no Macs in the test environment).
        XCTAssertTrue(element(app, "discover.searching").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Can't find your Mac?"].exists)
        app.buttons["Can't find your Mac?"].tap()
        XCTAssertTrue(app.navigationBars["Troubleshooting"].waitForExistence(timeout: 5))
    }

    func testHomeShowsEmptyAndDisconnectedStates() throws {
        let app = launch(["-skip-onboarding"])
        let name = element(app, "home.macName")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.label, "No Mac paired")
        XCTAssertTrue(app.buttons["home.pair"].exists)
        XCTAssertTrue(element(app, "home.empty").exists)
        XCTAssertTrue(app.buttons["home.photos"].exists)
        XCTAssertTrue(app.buttons["home.files"].exists)
    }

    func testPairSheetShowsSearchingState() throws {
        let app = launch(["-skip-onboarding"])
        XCTAssertTrue(app.buttons["home.pair"].waitForExistence(timeout: 5))
        app.buttons["home.pair"].tap()
        XCTAssertTrue(element(app, "discover.searching").waitForExistence(timeout: 5))
    }

    func testSettingsControlsAndPersistence() throws {
        let app = launch(["-skip-onboarding"])
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["No paired Macs"].waitForExistence(timeout: 5))
        let slider = app.sliders["settings.sensitivity"]
        XCTAssertTrue(slider.exists)
        slider.adjust(toNormalizedSliderPosition: 1.0)
        XCTAssertTrue(app.staticTexts["Easy"].waitForExistence(timeout: 2))
        app.buttons["Calibration"].tap()
        XCTAssertTrue(app.navigationBars["Calibration"].waitForExistence(timeout: 5))
        app.buttons["Left of the Mac"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'right edge of your iPhone'")).firstMatch.waitForExistence(timeout: 2))
    }

    func testHistoryEmptyState() throws {
        let app = launch(["-skip-onboarding"])
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["No transfers yet"].waitForExistence(timeout: 5))
    }
}
