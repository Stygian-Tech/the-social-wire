import XCTest

@MainActor
final class MacNewsShellSmokeUITests: XCTestCase {
    func testAdaptiveDestinationsAndFeedbackCommand() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing-news-shell")
        app.launch()

        XCTAssertTrue(content(for: "wire", in: app).waitForExistence(timeout: 5))

        for (label, identifier) in [
            ("Your Circle", "circle"),
            ("Library", "library"),
            ("Saved", "saved"),
            ("Search", "search"),
        ] {
            let destination = app.buttons[label]
            XCTAssertTrue(destination.waitForExistence(timeout: 2), "Missing \(label) destination")
            destination.click()
            XCTAssertTrue(content(for: identifier, in: app).waitForExistence(timeout: 2))
        }

        let helpMenu = app.menuBars.menuBarItems["Help"]
        XCTAssertTrue(helpMenu.waitForExistence(timeout: 2))
        helpMenu.click()
        let feedback = app.menuItems["Send Feedback…"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 2))
        feedback.click()
        XCTAssertTrue(app.staticTexts["Send Feedback"].waitForExistence(timeout: 3))
    }

    func testReadAgeMenuStreamsCountsAndCapsAtOneWeek() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-news-shell", "--ui-testing-read-age", "--ui-testing-read-age-stream",
        ]
        app.launch()
        let markRead = app.buttons["feed-mark-all-read"]
        XCTAssertTrue(markRead.waitForExistence(timeout: 5))
        markRead.rightClick()
        let firstDay = app.menuItems["mark-read-age-1"]
        XCTAssertTrue(firstDay.waitForExistence(timeout: 2))
        XCTAssertFalse(firstDay.isEnabled)
        let week = app.menuItems["mark-read-age-7"]
        XCTAssertTrue(week.waitForExistence(timeout: 10))
        XCTAssertTrue(week.isEnabled)
        XCTAssertFalse(app.menuItems["mark-read-age-8"].exists)
        week.click()
        XCTAssertTrue(app.staticTexts["Mark Older Stories As Read?"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].click()
    }

    private func content(for tab: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["news-tab-content-\(tab)"]
    }
}
