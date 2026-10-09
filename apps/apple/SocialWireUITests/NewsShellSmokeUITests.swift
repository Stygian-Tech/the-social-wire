import XCTest

@MainActor
final class NewsShellSmokeUITests: XCTestCase {
    func testRealShellNavigationKeepsPublicationAndArchiveActionsReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell"]
        app.launch()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))
        let subscribed = tabButton("Subscribed", in: app)
        XCTAssertTrue(subscribed.waitForExistence(timeout: 3))
        XCTAssertTrue(subscribed.isHittable)
        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        XCTAssertTrue(app.buttons["Add Publication"].waitForExistence(timeout: 3))
        app.buttons["Add Publication"].tap()
        XCTAssertTrue(app.navigationBars["Add Publication"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].firstMatch.tap()
        app.tabBars.buttons["Read Later"].tap()
        let archive = tabButton("Archive", in: app)
        XCTAssertTrue(archive.waitForExistence(timeout: 3))
        archive.tap()
        XCTAssertTrue(archive.isSelected)
        XCTAssertTrue(content(for: "saved", in: app).waitForExistence(timeout: 3))

        let readLater = app.navigationBars.buttons["Read Later"]
        XCTAssertTrue(readLater.waitForExistence(timeout: 3))
        readLater.tap()
        XCTAssertTrue(readLater.isSelected)

        app.tabBars.buttons["Feeds"].tap()
        subscribed.tap()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(add.waitForExistence(timeout: 3))
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
        app.tabBars.buttons["Read Later"].tap()
        XCTAssertTrue(content(for: "saved", in: app).waitForExistence(timeout: 3))
        app.buttons["fixture-select-publication"].tap()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(tabButton("Subscribed", in: app).isSelected)
        XCTAssertTrue(app.staticTexts["A Short Headline"].waitForExistence(timeout: 5))
        let markRead = app.buttons["feed-mark-all-read"]
        XCTAssertTrue(markRead.waitForExistence(timeout: 3))
        markRead.tap()
        let confirmation = app.alerts["Mark All As Read?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        // The fixture selects a publication without loading the sidebar's title index.
        XCTAssertTrue(confirmation.staticTexts["Mark every unread story in This Publication as read?"].exists)
        confirmation.buttons["Cancel"].tap()
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

    func testTopicsRemainReachableBeyondPrimaryTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-topics-lists"]
        app.launch()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))

        selectDestination("Finance", in: app)
        let chooseFinance = app.buttons["Choose Feed"]
        XCTAssertTrue(chooseFinance.waitForExistence(timeout: 5))
        chooseFinance.tap()
        XCTAssertTrue(app.navigationBars["Finance Feeds"].waitForExistence(timeout: 3))
        app.buttons["Done"].firstMatch.tap()

        selectDestination("Sports", in: app)
        let sportsPicker = app.buttons["sports-feed-picker"]
        XCTAssertTrue(sportsPicker.waitForExistence(timeout: 5))
        sportsPicker.tap()
        XCTAssertTrue(app.navigationBars["Sports Feeds"].waitForExistence(timeout: 3))
        app.buttons["Done"].firstMatch.tap()

        selectDestination("Subscribed", in: app)
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 3))
    }

    func testListsSelectionAndManagementRemainReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-topics-lists"]
        app.launch()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))
        selectDestination("Lists", in: app)
        XCTAssertTrue(content(for: "standardLists", in: app).waitForExistence(timeout: 5))
        let fixtureList = app.buttons["lists.row.at://did:plc:fixture/app.standard-reader.list/main"]
        XCTAssertTrue(fixtureList.waitForExistence(timeout: 5))
        fixtureList.tap()
        XCTAssertTrue(app.buttons["lists.entry.ui-story-1"].waitForExistence(timeout: 5))

        let manage = app.buttons["lists.manage"]
        if !manage.isHittable {
            let back = app.navigationBars.buttons["Lists"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 3))
            back.tap()
        }
        XCTAssertTrue(manage.waitForExistence(timeout: 3))
        manage.tap()
        XCTAssertTrue(app.navigationBars["Manage Lists"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["lists.searchInput"].exists)
        XCTAssertFalse(app.buttons["lists.search"].isEnabled)
        let name = app.textFields["lists.createName"]
        XCTAssertTrue(name.exists)
        XCTAssertFalse(app.buttons["lists.create"].isEnabled)
        let managementForm = app.collectionViews.containing(.textField, identifier: "lists.createName").firstMatch
        let delete = app.buttons["Delete Fixture List"]
        if !delete.isHittable { managementForm.swipeUp() }
        XCTAssertTrue(delete.isHittable)
        delete.tap()
        XCTAssertTrue(app.buttons["Delete List"].waitForExistence(timeout: 3))
        let cancel = app.buttons.matching(identifier: "Cancel").allElementsBoundByIndex.first { $0.isHittable }
        if let cancel {
            cancel.tap()
        } else {
            // The native iPad popover is outside the centered management sheet;
            // use the uncovered window corner to dismiss only the top popover.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.1)).tap()
        }
        XCTAssertTrue(app.buttons["Delete List"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Delete Fixture List"].exists)
        if !name.isHittable { managementForm.swipeDown() }
        name.tap()
        name.typeText("New Fixture List")
        XCTAssertTrue(app.buttons["lists.create"].isEnabled)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(fixtureList.waitForExistence(timeout: 3))
        fixtureList.tap()
        XCTAssertTrue(app.buttons["lists.entry.ui-story-1"].waitForExistence(timeout: 3))
    }

    func testEmptyListsManagementAndOtherDestinationsRemainReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-topics-lists", "--ui-testing-empty-lists"]
        app.launch()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))

        selectDestination("Lists", in: app)
        XCTAssertTrue(content(for: "standardLists", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Lists Yet"].waitForExistence(timeout: 3))
        let manage = app.buttons["lists.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 3))
        XCTAssertTrue(manage.isEnabled)
        XCTAssertTrue(manage.isHittable)
        manage.tap()
        XCTAssertTrue(app.navigationBars["Manage Lists"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["lists.createName"].exists)
        app.buttons["Done"].firstMatch.tap()

        selectDestination("Finance", in: app)
        XCTAssertTrue(app.buttons["Choose Feed"].waitForExistence(timeout: 5))
        selectDestination("Lists", in: app)
        XCTAssertTrue(app.staticTexts["No Lists Yet"].waitForExistence(timeout: 3))
        selectDestination("Read Later", in: app)
        XCTAssertTrue(content(for: "saved", in: app).waitForExistence(timeout: 5))
    }

    /// Follow compact root sections or regular-width sidebar destinations.
    private func selectDestination(_ label: String, in app: XCUIApplication) {
        let root: String? = switch label {
        case "Finance", "Sports": "Topics"
        case "Subscribed", "Following", "The Wire", "Your Circle": "Feeds"
        case "Archive": "Read Later"
        default: nil
        }
        if let root, app.tabBars.buttons[root].exists {
            app.tabBars.buttons[root].tap()
        }
        func destination() -> XCUIElement {
            let sidebarID: String? = switch label {
            case "Finance": "finance"
            case "Sports": "sports"
            case "The Wire": "wire"
            case "Your Circle": "circle"
            case "Lists": "standardLists"
            default: nil
            }
            if let sidebarID {
                let sidebarButton = app.buttons["news-tab-button-\(sidebarID)"]
                if sidebarButton.exists && sidebarButton.isHittable { return sidebarButton }
            }
            let tab = app.tabBars.buttons[label]
            if tab.exists && tab.isHittable { return tab }
            let capsule = app.navigationBars.buttons[label]
            if capsule.exists {
                let rail = app.navigationBars.scrollViews.firstMatch
                if rail.exists { revealHorizontally(capsule, in: rail) }
                if capsule.isHittable { return capsule }
            }
            // UIKit's compact More menu exposes destinations as cells with text
            // descendants, so activate the row rather than its static label.
            let cells = app.cells.containing(.staticText, identifier: label).allElementsBoundByIndex
            if let row = cells.first(where: { $0.isHittable }) { return row }
            let candidates = app.descendants(matching: .any)
                .matching(identifier: label).allElementsBoundByIndex
            if let visible = candidates.first(where: { $0.isHittable }) { return visible }
            // A hidden sidebar row must not prevent opening the compact overflow menu.
            return app.buttons["missing-destination-\(label)"]
        }
        if !destination().exists {
            // Grouped Topics can leave the floating top tab selected while hiding
            // other topic destinations behind the adaptive iPad sidebar.
            let toggles = [app.buttons["ToggleSideBar"], app.buttons["Toggle sidebar"]]
            if let toggle = toggles.first(where: { $0.exists && $0.isHittable }) {
                toggle.tap()
            }
        }
        if !destination().exists {
            let more = app.tabBars.buttons["More"]
            if more.exists && more.isHittable { more.tap() }
        }
        if !destination().exists {
            let topics = app.buttons["Topics"].firstMatch
            if topics.exists && topics.isHittable { topics.tap() }
        }
        let target = destination()
        XCTAssertTrue(target.waitForExistence(timeout: 3), "Missing destination: \(label)")
        XCTAssertTrue(target.isHittable, "Unreachable destination: \(label)")
        target.tap()
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
