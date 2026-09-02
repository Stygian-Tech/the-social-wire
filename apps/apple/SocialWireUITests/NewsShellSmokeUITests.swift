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
        XCTAssertTrue(app.buttons["mark-read-age-1"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["mark-read-age-2"].exists)
        XCTAssertTrue(app.buttons["mark-read-age-4"].exists)
        XCTAssertFalse(app.buttons["mark-read-age-3"].exists)
        app.buttons["mark-read-age-2"].tap()
        let olderConfirmation = app.alerts["Mark Older Stories As Read?"]
        XCTAssertTrue(olderConfirmation.waitForExistence(timeout: 3))
        olderConfirmation.buttons["Cancel"].tap()
        XCTAssertEqual(result.label, "Ready")

        markRead.press(forDuration: 1)
        app.buttons["mark-read-age-2"].tap()
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
        XCTAssertTrue(app.buttons["mark-read-age-1"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["mark-read-age-2"].exists)
        XCTAssertTrue(app.buttons["mark-read-age-4"].exists)
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

        let actionIDs = circle
            ? ["story-website", "story-read", "story-hide"]
            : ["story-website", "story-read"]
        let actions = actionIDs.map { identifier in
            app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        for action in actions {
            XCTAssertTrue(action.waitForExistence(timeout: 2))
        }
        if let last = actions.last { reveal(last, in: canvas) }

        let frames = actions.map(\.frame)
        for (index, frame) in frames.enumerated() {
            XCTAssertGreaterThanOrEqual(frame.width, 44, actionIDs[index])
            XCTAssertGreaterThanOrEqual(frame.height, 44, actionIDs[index])
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
        let expectedResults = circle ? ["Website", "Read", "Hidden"] : ["Website", "Read"]
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
            let secondRead = secondCard.descendants(matching: .any)["story-read"]
            XCTAssertTrue(secondRead.isHittable, "The longer second card must remain usable")
            XCTAssertLessThanOrEqual(secondRead.frame.maxY, rail.frame.maxY + 1)
        }
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
