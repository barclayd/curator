import XCTest

final class CuratorUITests: XCTestCase {
    @MainActor
    func testWelcomeAndSettingsAreAccessibleWithoutPhotoPermission() throws {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launch()
        XCTAssertTrue(app.navigationBars["Curator"].waitForExistence(timeout: 15))
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists,
                       "No Photos permission prompt should appear before the user chooses access.")
        XCTAssertTrue(app.buttons["Settings"].exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Allow cellular downloads"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Curator"].exists)
    }

    @MainActor
    func testReviewApprovalAndUndoWithFixtures() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-fixtures"]
        app.launch()
        let group = app.staticTexts["3 photos · 1 to remove"]
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        group.tap()
        XCTAssertTrue(app.navigationBars["Choose your keepers"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(identifier: "Keep").allElementsBoundByIndex.contains(where: { !$0.isEnabled }))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Group review"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Approve 1 removal"].tap()
        app.buttons["Review 1 removal"].tap()
        XCTAssertTrue(app.navigationBars["Your removals"].waitForExistence(timeout: 5))
        app.buttons["Undo approval"].tap()
        XCTAssertTrue(app.staticTexts["Nothing to remove"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Remove 0 photos"].isEnabled)
    }
}
