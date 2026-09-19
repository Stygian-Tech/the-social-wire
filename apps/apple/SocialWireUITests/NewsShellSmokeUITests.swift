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
        XCTAssertTrue(app.buttons["mark-read-age-7"].exists)
        XCTAssertFalse(app.buttons["mark-read-age-8"].exists)
        app.buttons["mark-read-age-2"].tap()
        let olderConfirmation = app.alerts["Mark Older Stories As Read?"]
        XCTAssertTrue(olderConfirmation.waitForExistence(timeout: 3))
        olderConfirmation.buttons["Cancel"].tap()
        XCTAssertEqual(result.label, "Ready")

        markRead.press(forDuration: 1)
        XCTAssertTrue(app.buttons["mark-read-age-2"].waitForExistence(timeout: 3))
        app.buttons["mark-read-age-2"].tap()
        XCTAssertTrue(olderConfirmation.waitForExistence(timeout: 3))
        olderConfirmation.buttons["Mark As Read"].tap()
        // The label already exists; wait for the asynchronous action to change it.
        let olderResult = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Read Before 2026-09-01T05:00:00Z"),
            object: result
        )
        XCTAssertEqual(XCTWaiter.wait(for: [olderResult], timeout: 5), .completed)
        XCTAssertEqual(result.label, "Read Before 2026-09-01T05:00:00Z")

        markRead.tap()
        let allConfirmation = app.alerts["Mark All As Read?"]
        XCTAssertTrue(allConfirmation.waitForExistence(timeout: 3))
        allConfirmation.buttons["Mark As Read"].tap()
        let allResult = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "All Read"),
            object: result
        )
        XCTAssertEqual(XCTWaiter.wait(for: [allResult], timeout: 5), .completed)
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

        let actionContainer: XCUIElement
        if circle {
            actionContainer = canvas
        } else {
            let firstCard = canvas.descendants(matching: .any)["wire-card-ui-story-1"]
            XCTAssertTrue(firstCard.waitForExistence(timeout: 2))
            XCTAssertGreaterThanOrEqual(firstCard.frame.width, 250)
            actionContainer = firstCard
        }

        let actionIDs = circle
            ? ["story-website", "story-read", "story-hide"]
            : ["story-website", "story-read"]
        let actions = actionIDs.map { identifier in
            // Every Wire card repeats these IDs; bind actions to the card under test.
            actionContainer.buttons[identifier]
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
            // The result exists before tapping; wait for the callback to update it.
            let callback = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", expected),
                object: result
            )
            XCTAssertEqual(XCTWaiter.wait(for: [callback], timeout: 5), .completed)
            XCTAssertEqual(result.label, expected)
        }

        if !circle {
            let rail = canvas.scrollViews.firstMatch
            let secondCard = canvas.descendants(matching: .any)["wire-card-ui-story-2"]
            XCTAssertTrue(secondCard.waitForExistence(timeout: 2))
            XCTAssertGreaterThanOrEqual(secondCard.frame.width, 250)
            let secondRead = secondCard.buttons["story-read"]
            revealHorizontally(secondRead, in: rail)
            reveal(secondRead, in: canvas)
            XCTAssertTrue(secondRead.isHittable, "The longer second card must remain usable")
            XCTAssertLessThanOrEqual(secondRead.frame.maxY, rail.frame.maxY + 1)
        }
    }

    private func revealHorizontally(_ element: XCUIElement, in scrollView: XCUIElement) {
        // A single swipe does not guarantee the same resting offset on every runner.
        for _ in 0..<6 {
            let frame = element.frame
            let viewport = scrollView.frame
            if frame.minX >= viewport.minX, frame.maxX <= viewport.maxX { return }
            if frame.minX < viewport.minX {
                scrollView.swipeRight()
            } else {
                scrollView.swipeLeft()
            }
        }
    }

    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement) {
        for _ in 0..<6 {
            let frame = element.frame
            let viewport = scrollView.frame
            // Hittability alone can accept a clipped action near a scroll edge.
            if frame.minY >= viewport.minY, frame.maxY <= viewport.maxY,
               element.isHittable { break }
            if frame.minY < viewport.minY {
                scrollView.swipeDown()
            } else if frame.maxY > viewport.maxY {
                scrollView.swipeUp()
            } else {
                // Scrolling cannot resolve an action that is fully visible but blocked.
                break
            }
        }
        let frame = element.frame
        let viewport = scrollView.frame
        XCTAssertGreaterThanOrEqual(
            frame.minY, viewport.minY,
            "Action must be fully visible before tapping: \(frame), viewport: \(viewport)"
        )
        XCTAssertLessThanOrEqual(
            frame.maxY, viewport.maxY,
            "Action must be fully visible before tapping: \(frame), viewport: \(viewport)"
        )
        XCTAssertTrue(
            element.isHittable,
            "Action must accept a tap after reveal: \(frame), viewport: \(viewport)"
        )
    }

    private func content(for tab: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["news-tab-content-\(tab)"]
    }
}
