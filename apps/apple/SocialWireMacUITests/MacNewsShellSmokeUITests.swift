import XCTest

@MainActor
final class MacNewsShellSmokeUITests: XCTestCase {
    func testAdaptiveDestinationsAndFeedbackCommand() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-shell-routing"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["news-sidebar-column"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["news-detail-column"].waitForExistence(timeout: 5))
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))

        for label in ["Read Later", "Archive"] {
            let destination = app.buttons[label].firstMatch
            XCTAssertTrue(destination.waitForExistence(timeout: 3), "Missing \(label) destination")
            destination.click()
            XCTAssertTrue(content(for: "saved", in: app).waitForExistence(timeout: 3))
        }

        app.buttons["fixture-select-publication"].click()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Fixture Publication"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 3))

        let helpMenu = app.menuBars.menuBarItems["Help"]
        XCTAssertTrue(helpMenu.waitForExistence(timeout: 2))
        helpMenu.click()
        let feedback = app.menuItems["Send Feedback…"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 2))
        feedback.click()
        XCTAssertTrue(app.staticTexts["Send Feedback"].waitForExistence(timeout: 3))
    }

    private func content(for tab: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["news-tab-content-\(tab)"]
    }
}
