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

        let subscribed = app.navigationBars.buttons["Subscribed"].firstMatch
        XCTAssertTrue(subscribed.isSelected)
        XCTAssertTrue(subscribed.isHittable)
        subscribed.tap()
        assertScope("All Subscribed", in: app)
    }

    func testPreferenceUpdatesAndTabChangesPreserveChosenPublication() throws {
        let app = try launch()
        app.buttons["fixture-select-publication"].tap()
        assertScope("One Publication", in: app)
        app.buttons["fixture-refresh-preferences"].tap()
        assertScope("One Publication", in: app)
        XCTAssertTrue(app.staticTexts["A Short Headline"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Read Later"].tap()
        app.tabBars.buttons["News"].tap()
        assertScope("One Publication", in: app)
        XCTAssertTrue(app.staticTexts["A Short Headline"].waitForExistence(timeout: 5))
    }

    func testFollowingShortcutChangesTheActiveFeed() throws {
        let app = try launch(sidebarPublications: true)
        let following = app.navigationBars.buttons["Following"].firstMatch
        XCTAssertTrue(following.waitForExistence(timeout: 5))
        let rail = app.navigationBars.scrollViews.firstMatch
        for _ in 0..<4 where !following.isHittable { rail.swipeLeft() }
        XCTAssertTrue(following.isHittable)
        following.tap()
        assertScope("All Following", in: app)
        XCTAssertTrue(app.tabBars.buttons["News"].isSelected)
    }

    private func assertScope(_ expected: String, in app: XCUIApplication) {
        let scope = app.staticTexts["fixture-reader-scope"]
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: scope)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed)
    }
}
