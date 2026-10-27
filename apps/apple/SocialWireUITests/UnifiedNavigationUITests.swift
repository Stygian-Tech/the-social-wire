import XCTest
import UIKit

@MainActor
final class UnifiedNavigationUITests: XCTestCase {
    private func launch(compactWindow: Bool = false, additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-topics-lists", "--ui-testing-reset-tabs"] + additionalArguments
        if compactWindow { app.launchArguments.append("--ui-testing-compact-window") }
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["news-tab-content-library"].firstMatch.waitForExistence(timeout: 8))
        return app
    }

    func testPhoneHasExactlyFourNativeTabs() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone tab bar")
        let app = launch()
        XCTAssertEqual(app.tabBars.buttons.count, 4)
        for title in ["Read Later", "News", "Topics", "Lists"] {
            XCTAssertTrue(app.tabBars.buttons[title].exists, title)
        }
        XCTAssertFalse(app.tabBars.buttons["More"].exists)
        XCTAssertFalse(app.tabBars.buttons["Social"].exists)
        XCTAssertFalse(app.tabBars.buttons["Browse"].exists)
    }

    func testNativeSectionsRemainReachableOnPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Adaptive iPad tabs and sidebar")
        assertSections(in: launch())
    }

    func testNativeSectionsRemainReachableOnCompactPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Compact iPad native tabs")
        assertSections(in: launch(compactWindow: true))
    }

    func testReadLaterAndArchiveSwitchWithHorizontalSwipes() {
        let app = launch()
        selectRoot("Read Later", in: app)
        let saved = app.descendants(matching: .any)["news-tab-content-saved"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        assertSelectedFeed("Read Later", in: app)
        saved.swipeLeft()
        assertSelectedFeed("Archive", in: app)
        saved.swipeRight()
        assertSelectedFeed("Read Later", in: app)
    }

    func testNewsFeedsSwitchWithHorizontalSwipesAndRememberSelection() {
        let app = launch()
        let library = app.descendants(matching: .any)["news-tab-content-library"].firstMatch
        assertSelectedFeed("Subscribed", in: app)
        library.swipeLeft()
        assertSelectedFeed("Following", in: app)
        selectRoot("Read Later", in: app)
        selectRoot("News", in: app)
        assertSelectedFeed("Following", in: app)
        library.swipeRight()
        assertSelectedFeed("Subscribed", in: app)
    }

    func testSubscribedPublicationsRemainReachableWithoutCustomSidebar() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-sidebar-publications"]
        app.launch()
        let browse = app.buttons["news-browse-publications"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        browse.tap()
        let publication = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Subscribed Publication'" )).firstMatch
        XCTAssertTrue(publication.waitForExistence(timeout: 5))
        publication.tap()
        XCTAssertTrue(app.descendants(matching: .any)["news-tab-content-library"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(browse.isHittable)
    }

    func testTopicsFeedsSwitchWithHorizontalSwipes() {
        let app = launch()
        selectRoot("Topics", in: app)
        let finance = app.descendants(matching: .any)["news-tab-content-finance"].firstMatch
        XCTAssertTrue(finance.waitForExistence(timeout: 5))
        finance.swipeLeft()
        XCTAssertTrue(app.descendants(matching: .any)["news-tab-content-sports"].firstMatch.waitForExistence(timeout: 5))
    }

    func testListFeedsSwitchWithHorizontalSwipes() {
        let app = launch(additionalArguments: ["--ui-testing-list-swipes"])
        selectRoot("Lists", in: app)
        app.buttons["lists.row.at://did:plc:fixture/app.standard-reader.list/main"].tap()
        let articles = app.descendants(matching: .any)["lists.articles"].firstMatch
        XCTAssertTrue(articles.waitForExistence(timeout: 5))
        articles.swipeLeft()
        XCTAssertTrue(app.navigationBars["Second List"].waitForExistence(timeout: 5))
        articles.swipeRight()
        XCTAssertTrue(app.navigationBars["Fixture List"].waitForExistence(timeout: 5))
    }

    func testAccountLogOutIsReachableFromNativeToolbar() {
        let app = launch()
        let profile = app.buttons["Profile"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertTrue(profile.isHittable)
        profile.tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        let logout = app.buttons["account-log-out"]
        XCTAssertTrue(logout.waitForExistence(timeout: 5))
        for _ in 0..<6 where !logout.isHittable { app.swipeUp() }
        XCTAssertTrue(logout.isHittable)
        app.navigationBars["Profile"].buttons["Done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["news-tab-content-library"].firstMatch.waitForExistence(timeout: 5))
    }

    private func assertSections(in app: XCUIApplication) {
        for (title, content) in [("Read Later", "saved"), ("News", "library"), ("Topics", "finance"), ("Lists", "standardLists")] {
            selectRoot(title, in: app)
            XCTAssertTrue(app.descendants(matching: .any)["news-tab-content-\(content)"].waitForExistence(timeout: 5), title)
        }
        XCTAssertFalse(app.buttons["news-customize-sections"].exists)
        XCTAssertFalse(app.buttons["news-social-timeline"].exists)
    }

    private func assertSelectedFeed(_ title: String, in app: XCUIApplication) {
        let picker = app.buttons["news-feed-picker"].firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", title), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }

    private func selectRoot(_ title: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title].firstMatch
        if tab.exists && tab.isHittable { tab.tap(); return }
        let matches = app.buttons.matching(identifier: title).allElementsBoundByIndex
        if let visible = matches.first(where: { $0.isHittable }) {
            visible.tap()
            return
        }
        let toggles = ["ToggleSidebar", "ToggleSideBar", "Toggle sidebar", "Show Sidebar"]
        if let toggle = toggles.map({ app.buttons[$0].firstMatch }).first(where: { $0.exists && $0.isHittable }) { toggle.tap() }
        let button = app.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable)
        button.tap()
    }
}
