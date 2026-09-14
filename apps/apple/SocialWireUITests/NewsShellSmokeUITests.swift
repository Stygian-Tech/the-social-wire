import XCTest

@MainActor
final class NewsShellSmokeUITests: XCTestCase {
    func testRealShellSidebarKeepsPublicationAndArchiveActionsReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell"]
        app.launch()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))
        openSidebar(in: app)
        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        XCTAssertTrue(app.buttons["Add Publication"].waitForExistence(timeout: 3))
        app.buttons["Add Publication"].tap()
        XCTAssertTrue(app.navigationBars["Add Publication"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].firstMatch.tap()
        let archive = app.buttons["Archive"].firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 3))
        archive.tap()
        XCTAssertTrue(app.navigationBars["Archive"].waitForExistence(timeout: 3))
    }

    func testRealShellReconcilesHydratedVisibilityAndPublicationSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-shell-routing"]
        app.launch()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))
        let following = app.tabBars.buttons["Following"]
        XCTAssertTrue(following.waitForExistence(timeout: 3))
        app.buttons["fixture-hide-following"].tap()
        XCTAssertTrue(following.waitForNonExistence(timeout: 3))
        app.tabBars.buttons["Read Later"].tap()
        XCTAssertTrue(content(for: "saved", in: app).waitForExistence(timeout: 3))
        app.buttons["fixture-select-publication"].tap()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Fixture Publication"].waitForExistence(timeout: 3))
    }

    private func openSidebar(in app: XCUIApplication) {
        let button = app.buttons["news-open-sidebar"]
        if button.waitForExistence(timeout: 2) { button.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["news-sidebar-column"].waitForExistence(timeout: 3))
    }

    func testWireCardsFitNarrowCanvas() {
        assertFeedCards(circle: false, largeText: false)
    }

    func testReadAgeMenuUsesAvailableDaysAndRequiresConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-read-age"]
        app.launch()
        let markRead = app.buttons["feed-mark-all-read"]
        let result = app.staticTexts["feed-action-result"]
        XCTAssertTrue(markRead.waitForExistence(timeout: 5))

        markRead.press(forDuration: 1)
        XCTAssertTrue(ageButton(days: 1, in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(ageButton(days: 2, in: app).exists)
        XCTAssertTrue(ageButton(days: 4, in: app).exists)
        XCTAssertFalse(ageButton(days: 3, in: app).exists)
        ageButton(days: 2, in: app).tap()
        let olderConfirmation = app.alerts["Mark Older Stories As Read?"]
        XCTAssertTrue(olderConfirmation.waitForExistence(timeout: 3))
        olderConfirmation.buttons["Cancel"].tap()
        XCTAssertEqual(result.label, "Ready")

        markRead.press(forDuration: 1)
        ageButton(days: 2, in: app).tap()
        olderConfirmation.buttons["Mark As Read"].tap()
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        XCTAssertEqual(result.label, "Read Before 2026-09-01T05:00:00Z")

        markRead.tap()
        let allConfirmation = app.alerts["Mark All As Read?"]
        XCTAssertTrue(allConfirmation.waitForExistence(timeout: 3))
        allConfirmation.buttons["Mark As Read"].tap()
        XCTAssertEqual(result.label, "All Read")

        app.buttons["fixture-read-stories"].tap()
        markRead.press(forDuration: 1)
        XCTAssertTrue(ageButton(days: 1, in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(ageButton(days: 2, in: app).exists)
        XCTAssertTrue(ageButton(days: 4, in: app).exists)
    }

    func testWireCardsFitNarrowCanvasWithAccessibilityText() {
        assertFeedCards(circle: false, largeText: true)
    }

    func testCircleActionsFitNarrowCanvas() {
        assertFeedCards(circle: true, largeText: false)
    }

    func testCircleActionsFitNarrowCanvasWithAccessibilityText() {
        assertFeedCards(circle: true, largeText: true)
    }

    private func assertFeedCards(circle: Bool, largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-feed-cards"]
        if circle { app.launchArguments.append("--ui-testing-circle") }
        if largeText { app.launchArguments.append("--ui-testing-large-text") }
        app.launch()

        let canvas = app.scrollViews["feed-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertEqual(canvas.frame.width, 320, accuracy: 1)

        if !circle {
            let firstCard = app.descendants(matching: .any)["wire-card-ui-story-1"]
            XCTAssertTrue(firstCard.waitForExistence(timeout: 2))
            XCTAssertGreaterThanOrEqual(firstCard.frame.width, 250)
        }

        let actionSpecs = circle
            ? [("story-open", "Open Story"), ("story-hide", "Hide Story")]
            : [("story-open", "Open Story")]
        let actions = actionSpecs.map { identifier, label in
            let identified = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            return identified.exists ? identified : app.buttons[label]
        }
        let actionIDs = actionSpecs.map(\.0)
        for action in actions {
            XCTAssertTrue(action.waitForExistence(timeout: 2))
        }
        if let last = actions.last { reveal(last, in: canvas) }

        let frames = actions.map(\.frame)
        for (index, frame) in frames.enumerated() {
            XCTAssertGreaterThanOrEqual(frame.width, 43.5, actionIDs[index])
            XCTAssertGreaterThanOrEqual(frame.height, 43.5, actionIDs[index])
            XCTAssertGreaterThanOrEqual(frame.minX, canvas.frame.minX - 1, actionIDs[index])
            XCTAssertLessThanOrEqual(frame.maxX, canvas.frame.maxX + 1, actionIDs[index])
            for otherFrame in frames.dropFirst(index + 1) {
                XCTAssertFalse(
                    frame.insetBy(dx: 1, dy: 1).intersects(otherFrame),
                    "Feed actions overlap"
                )
            }
        }

        let result = app.staticTexts["feed-action-result"]
        let expectedResults = circle ? ["Open", "Hidden"] : ["Open"]
        for (action, expected) in zip(actions, expectedResults) {
            reveal(action, in: canvas)
            XCTAssertTrue(action.isHittable)
            action.tap()
            XCTAssertTrue(result.waitForExistence(timeout: 2))
            XCTAssertEqual(result.label, expected)
        }

        if !circle {
            let rail = canvas.scrollViews.firstMatch
            rail.swipeLeft()
            let secondCard = app.descendants(matching: .any)["wire-card-ui-story-2"]
            XCTAssertTrue(secondCard.waitForExistence(timeout: 2))
            XCTAssertGreaterThanOrEqual(secondCard.frame.width, 250)
            let secondOpen = secondCard.descendants(matching: .any)["story-open"]
            XCTAssertTrue(secondOpen.isHittable, "The longer second card must remain usable")
            XCTAssertLessThanOrEqual(secondOpen.frame.maxY, rail.frame.maxY + 1)
        }
    }

    private func ageButton(days: Int, in app: XCUIApplication) -> XCUIElement {
        let identified = app.buttons["mark-read-age-\(days)"]
        if identified.exists {
            return identified
        }
        return app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", days == 1 ? "1 Day" : "\(days) Days")
        ).firstMatch
    }

    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement) {
        for _ in 0..<6 {
            if element.isHittable { return }
            if element.frame.midY < scrollView.frame.minY {
                scrollView.swipeDown()
            } else {
                scrollView.swipeUp()
            }
        }
    }

    private func content(for tab: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["news-tab-content-\(tab)"]
    }
}
