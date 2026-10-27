import UIKit
import XCTest

@MainActor
final class ReaderNavigationReliabilityUITests: XCTestCase {
    private func launch(sidebarPublications: Bool = false) throws -> XCUIApplication {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone aggregate shortcut navigation")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-shell-routing", "--ui-testing-reset-tabs"]
        if sidebarPublications { app.launchArguments.append("--ui-testing-sidebar-publications") }
        app.launch()
        XCTAssertTrue(app.buttons["fixture-select-publication"].waitForExistence(timeout: 5))
        return app
    }

    func testSelectedSubscribedShortcutReturnsFromPublicationToFullFeed() throws {
        let app = try launch()
        app.buttons["fixture-select-publication"].tap()
        assertScope("One Publication", in: app)
        XCTAssertTrue(app.staticTexts["A Short Headline"].waitForExistence(timeout: 5))

        let picker = app.buttons["news-feed-picker"].firstMatch
        XCTAssertEqual(picker.value as? String, "Subscribed")
        selectFeed("Subscribed", in: app)
        assertScope("All Subscribed", in: app)
    }

    func testPreferenceUpdatesAndTabChangesPreserveChosenPublication() throws {
        let app = try launch()
        app.buttons["fixture-select-publication"].tap()
        assertScope("One Publication", in: app)
        app.buttons["fixture-refresh-preferences"].tap()
        assertScope("One Publication", in: app)
        XCTAssertTrue(app.staticTexts["A Short Headline"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Topics"].tap()
        app.tabBars.buttons["News"].tap()
        assertScope("One Publication", in: app)
        XCTAssertTrue(app.staticTexts["A Short Headline"].waitForExistence(timeout: 5))
    }

    func testFollowingShortcutChangesTheActiveFeed() throws {
        let app = try launch(sidebarPublications: true)
        selectFeed("Following", in: app)
        assertScope("All Following", in: app)
        XCTAssertTrue(app.tabBars.buttons["News"].isSelected)
    }

    private func selectFeed(_ title: String, in app: XCUIApplication) {
        let picker = app.buttons["news-feed-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let option = app.buttons[title].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", title), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }

    private func assertScope(_ expected: String, in app: XCUIApplication) {
        let scope = app.staticTexts["fixture-reader-scope"]
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: scope)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed)
    }
}
