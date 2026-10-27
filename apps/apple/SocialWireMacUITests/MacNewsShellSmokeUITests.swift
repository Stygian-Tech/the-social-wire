import XCTest

@MainActor
final class MacNewsShellSmokeUITests: XCTestCase {
    func testAdaptiveDestinationsAndFeedbackCommand() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-shell-routing", "--ui-testing-topics-lists", "--ui-testing-reset-tabs"]
        app.launch()

        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))
        for (title, destination) in [("Read Later", "saved"), ("News", "library"), ("Topics", "finance"), ("Lists", "standardLists")] {
            selectRoot(title, in: app)
            XCTAssertTrue(content(for: destination, in: app).waitForExistence(timeout: 5), title)
        }
        XCTAssertFalse(app.buttons["news-customize-sections"].exists)
        XCTAssertFalse(app.buttons["news-social-timeline"].exists)
        selectRoot("Read Later", in: app)

        for label in ["Read Later", "Archive"] {
            let picker = app.buttons["news-feed-picker"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 3))
            picker.click()
            let destination = app.menuItems[label].firstMatch
            XCTAssertTrue(destination.waitForExistence(timeout: 3), "Missing \(label) destination")
            destination.click()
            XCTAssertTrue(content(for: "saved", in: app).waitForExistence(timeout: 3))
        }

        selectRoot("News", in: app)
        app.buttons["fixture-select-publication"].click()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["A Short Headline"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 3))

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

    private func selectRoot(_ title: String, in app: XCUIApplication) {
        let radio = app.radioButtons[title].firstMatch
        if radio.exists && radio.isHittable { radio.click(); return }
        let tab = app.tabBars.buttons[title].firstMatch
        if tab.exists && tab.isHittable { tab.click(); return }
        if let button = app.buttons.matching(identifier: title).allElementsBoundByIndex.first(where: { $0.isHittable }) {
            button.click()
            return
        }
        for label in ["ToggleSidebar", "ToggleSideBar", "Toggle sidebar", "Show Sidebar"] {
            let toggle = app.buttons[label].firstMatch
            if toggle.exists && toggle.isHittable { toggle.click(); break }
        }
        let button = app.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing native \(title) destination")
        XCTAssertTrue(button.isHittable)
        button.click()
    }

    private func content(for tab: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["news-tab-content-\(tab)"]
    }
}
