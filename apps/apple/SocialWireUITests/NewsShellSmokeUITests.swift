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
        let archive = tabButton("Archive", in: app)
        XCTAssertTrue(archive.waitForExistence(timeout: 3))
        archive.tap()
        XCTAssertTrue(app.navigationBars["Archive"].waitForExistence(timeout: 3))
    }

    func testRealShellReconcilesHydratedVisibilityAndPublicationSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-shell-routing"]
        app.launch()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))
        let following = tabButton("Following", in: app)
        XCTAssertTrue(following.waitForExistence(timeout: 3))
        app.buttons["fixture-hide-following"].tap()
        XCTAssertTrue(following.waitForNonExistence(timeout: 3))
        tabButton("Read Later", in: app).tap()
        XCTAssertTrue(content(for: "saved", in: app).waitForExistence(timeout: 3))
        app.buttons["fixture-select-publication"].tap()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Fixture Publication"].waitForExistence(timeout: 5))
    }

    private func tabButton(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let tabBarButton = app.tabBars.buttons[label]
        if tabBarButton.waitForExistence(timeout: 1) {
            return tabBarButton
        }
        let button = app.buttons[label]
        if button.waitForExistence(timeout: 1) {
            return button
        }
        return app.descendants(matching: .any)[label].firstMatch
    }

    private func openSidebar(in app: XCUIApplication) {
        let button = app.buttons["news-open-sidebar"]
        let toggleButton = app.buttons["ToggleSidebar"]
        if button.waitForExistence(timeout: 2) {
            button.tap()
        } else if toggleButton.waitForExistence(timeout: 1), toggleButton.label.contains("Show") {
            toggleButton.tap()
        }
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
        XCTAssertTrue(ageButton(days: 7, in: app).exists)
        XCTAssertFalse(ageButton(days: 8, in: app).exists)
        ageButton(days: 2, in: app).tap()
        let olderConfirmation = app.alerts["Mark Older Stories As Read?"]
        XCTAssertTrue(olderConfirmation.waitForExistence(timeout: 3))
        olderConfirmation.buttons["Cancel"].tap()
        XCTAssertEqual(result.label, "Ready")

        markRead.press(forDuration: 1)
        ageButton(days: 2, in: app).tap()
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

        let actionContainer: XCUIElement
        if circle {
            actionContainer = canvas
        } else {
            let firstCard = canvas.descendants(matching: .any)["wire-card-ui-story-1"]
            XCTAssertTrue(firstCard.waitForExistence(timeout: 2))
            XCTAssertGreaterThanOrEqual(firstCard.frame.width, 250)
            actionContainer = firstCard
        }

        let actionSpecs = circle
            ? [("story-open", "Open Story"), ("story-hide", "Hide Story")]
            : [("story-open", "Open Story")]
        let actions = actionSpecs.map { identifier, label in
            let identified = actionContainer.descendants(matching: .any).matching(identifier: identifier).firstMatch
            return identified.exists ? identified : actionContainer.buttons[label]
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
            let secondOpen = secondCard.descendants(matching: .any)["story-open"]
            revealHorizontally(secondOpen, in: rail)
            reveal(secondOpen, in: canvas)
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
            NSPredicate(format: "label BEGINSWITH %@", days == 7 ? "1 Week" : days == 1 ? "1 Day" : "\(days) Days")
        ).firstMatch
    }

    private func revealHorizontally(_ element: XCUIElement, in scrollView: XCUIElement) {
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
