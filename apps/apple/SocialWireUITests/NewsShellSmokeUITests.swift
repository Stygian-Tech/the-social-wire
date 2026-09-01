import XCTest

@MainActor
final class NewsShellSmokeUITests: XCTestCase {
    func testFiveDestinationsNavigateIndependently() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing-news-shell")
        app.launch()

        XCTAssertTrue(content(for: "wire", in: app).waitForExistence(timeout: 5))

        let destinations = [
            ("Your Circle", "circle"),
            ("Library", "library"),
            ("Saved", "saved"),
            ("Search", "search"),
        ]
        for (label, identifier) in destinations {
            var destination = app.buttons[label]
            if label == "Search", !destination.exists, app.buttons["Next Page"].exists {
                app.buttons["Next Page"].tap()
                destination = app.buttons[label]
            }
            XCTAssertTrue(destination.waitForExistence(timeout: 2), "Missing \(label) destination")
            destination.tap()
            XCTAssertTrue(
                content(for: identifier, in: app).waitForExistence(timeout: 2),
                "Did not show \(label) content"
            )
        }
    }

    private func content(for tab: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["news-tab-content-\(tab)"]
    }
}
