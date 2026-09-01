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

    private func content(for tab: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["news-tab-content-\(tab)"]
    }
}
