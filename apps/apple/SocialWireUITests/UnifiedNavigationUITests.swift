import XCTest
import UIKit

@MainActor
final class UnifiedNavigationUITests: XCTestCase {
    private func launch(resetTabs: Bool = true, compactWindow: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-topics-lists"]
        if resetTabs { app.launchArguments.append("--ui-testing-reset-tabs") }
        if compactWindow { app.launchArguments.append("--ui-testing-compact-window") }
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["news-tab-content-library"].waitForExistence(timeout: 8))
        return app
    }

    func testPhoneUsesNativeFavoritesAndBrowse() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone tab layout")
        let app = launch()
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        for title in ["Read Later", "News", "Social", "Topics", "Browse"] {
            XCTAssertTrue(app.tabBars.buttons[title].exists, title)
        }
        app.tabBars.buttons["Browse"].tap()
        let lists = app.buttons["news-tab-button-standardLists"]
        reveal(lists, in: app)
        lists.tap()
        XCTAssertTrue(app.buttons["lists.manage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Browse"].isSelected)
        XCTAssertFalse(app.tabBars.buttons["Lists"].exists)
        app.tabBars.buttons["News"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["news-tab-content-library"].waitForExistence(timeout: 5))
    }

    func testSocialDestinationsUseTheSharedSidebar() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone sidebar navigation")
        let app = launch()
        app.tabBars.buttons["Browse"].tap()
        let explore = app.buttons["news-social-explore"]
        reveal(explore, in: app)
        explore.tap()
        XCTAssertTrue(app.navigationBars["Explore"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Social"].isSelected)
        XCTAssertFalse(app.buttons["news-social-timeline"].isHittable)
        app.buttons["news-show-sidebar"].firstMatch.tap()
        let notifications = app.buttons["news-social-notifications"]
        reveal(notifications, in: app)
        notifications.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
    }

    func testPhoneCustomizationPersistsAndKeepsBrowse() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone tab customization")
        let app = launch()
        app.tabBars.buttons["Browse"].tap()
        let customize = app.buttons["news-customize-sections"]
        reveal(customize, in: app)
        customize.tap()
        let removeTopics = app.buttons["section-unpin-topics"]
        XCTAssertTrue(removeTopics.waitForExistence(timeout: 3))
        removeTopics.tap()
        app.buttons["section-pin-lists"].tap()
        app.navigationBars["Customize Bottom Bar"].buttons["Done"].tap()
        XCTAssertTrue(app.tabBars.buttons["Lists"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.buttons["Topics"].exists)
        XCTAssertTrue(app.tabBars.buttons["Browse"].exists)
        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-testing-reset-tabs" }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Lists"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.tabBars.buttons["Topics"].exists)
        XCTAssertTrue(app.tabBars.buttons["Browse"].exists)
    }

    func testSidebarUsesWebLabelsAndKeepsUnreleasedToolsHidden() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone Browse catalog")
        let app = launch()
        app.tabBars.buttons["Browse"].tap()
        XCTAssertEqual(app.buttons["news-saved"].label, "Saved")
        XCTAssertEqual(app.buttons["news-social-timeline"].label, "Home")
        XCTAssertFalse(app.buttons["news-social-proTools"].exists)
        let news = app.buttons["sidebar-section-feeds"]
        reveal(news, in: app)
        XCTAssertEqual(news.label, "News")
        let lists = app.buttons["news-tab-button-standardLists"]
        reveal(lists, in: app)
        for tool in ["articles", "livePost", "livestream", "brandAccounts", "contentCalendar", "analytics"] {
            XCTAssertFalse(app.buttons["news-tool-\(tool)"].exists)
        }
        XCTAssertFalse(app.staticTexts["Tools"].exists)
    }

    func testPadHasSidebarWithoutTabBarOrPhoneCustomization() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sidebar layout")
        let app = launch()
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        let lists = app.buttons["news-tab-button-standardLists"]
        reveal(lists, in: app)
        XCTAssertTrue(lists.exists)
        let sidebar = app.descendants(matching: .any)["news-sidebar"].firstMatch
        sidebar.swipeDown()
        sidebar.swipeDown()
        let explore = app.buttons["news-social-explore"]
        reveal(explore, in: app)
        explore.tap()
        XCTAssertTrue(app.navigationBars["Explore"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["news-customize-sections"].exists)
    }

    func testCompactPadKeepsSidebarNavigationWithoutTabs() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Compact iPad sidebar layout")
        let app = launch(compactWindow: true)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        openSidebarIfNeeded(in: app)
        let explore = app.buttons["news-social-explore"]
        reveal(explore, in: app)
        explore.tap()
        XCTAssertTrue(app.navigationBars["Explore"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["news-customize-sections"].exists)
    }

    func testCompactPadCanOpenAReaderListFromTheSharedSidebar() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Compact iPad list navigation")
        let app = launch(compactWindow: true)
        openSidebarIfNeeded(in: app)
        let list = app.buttons["Fixture List"].firstMatch
        reveal(list, in: app)
        list.tap()
        XCTAssertTrue(app.buttons["lists.entry.ui-story-1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }

    private func openSidebarIfNeeded(in app: XCUIApplication) {
        if app.buttons["news-social-explore"].exists && app.buttons["news-social-explore"].isHittable { return }
        let candidates = [app.buttons["news-show-sidebar"].firstMatch,
                          app.navigationBars.buttons["The Social Wire"].firstMatch,
                          app.buttons["ToggleSidebar"].firstMatch,
                          app.buttons["Toggle sidebar"].firstMatch]
        if let button = candidates.first(where: { $0.exists && $0.isHittable }) { button.tap() }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let sidebar = app.descendants(matching: .any)["news-sidebar"].firstMatch
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            if sidebar.exists {
                if element.exists && element.frame.minY < sidebar.frame.minY {
                    sidebar.swipeDown()
                } else {
                    sidebar.swipeUp()
                }
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
}
