import XCTest

@MainActor
final class NewsShellSmokeUITests: XCTestCase {
    func testRealShellNavigationKeepsPublicationAndArchiveActionsReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-reset-tabs"]
        app.launch()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))
        assertSelectedFeed("Subscribed", in: app)
        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        XCTAssertTrue(app.buttons["Add Publication"].waitForExistence(timeout: 3))
        app.buttons["Add Publication"].tap()
        XCTAssertTrue(app.navigationBars["Add Publication"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].firstMatch.tap()
        selectRoot("Read Later", in: app)
        selectFeed("Archive", in: app)
        XCTAssertTrue(content(for: "saved", in: app).waitForExistence(timeout: 3))
        selectFeed("Read Later", in: app)
        selectRoot("News", in: app)
        selectFeed("Subscribed", in: app)
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(add.waitForExistence(timeout: 3))
    }

    func testRealShellReconcilesHydratedVisibilityAndPublicationSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-reset-tabs", "--ui-testing-shell-routing"]
        app.launch()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))
        let picker = app.buttons["news-feed-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.tap()
        XCTAssertTrue(app.buttons["Following"].waitForExistence(timeout: 3))
        app.buttons["Subscribed"].firstMatch.tap()
        app.buttons["fixture-hide-following"].tap()
        picker.tap()
        XCTAssertFalse(app.buttons["Following"].exists)
        app.buttons["Subscribed"].firstMatch.tap()
        selectRoot("Read Later", in: app)
        XCTAssertTrue(content(for: "saved", in: app).waitForExistence(timeout: 3))
        app.buttons["fixture-select-publication"].tap()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))
        assertSelectedFeed("Subscribed", in: app)
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

    func testTopicFeedsRemainReachableFromNativeTopicsTab() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-reset-tabs", "--ui-testing-topics-lists"]
        app.launch()
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 5))

        selectDestination("Finance", in: app)
        let chooseFinance = app.buttons["Choose Feed"]
        XCTAssertTrue(chooseFinance.waitForExistence(timeout: 5))
        chooseFinance.tap()
        guard dismissPicker("Finance Feeds", in: app) else { return }

        selectDestination("Sports", in: app)
        XCTAssertTrue(app.staticTexts["Fixture Football Story"].waitForExistence(timeout: 5))
        let sportsPicker = app.buttons["sports-feed-picker"]
        XCTAssertTrue(sportsPicker.waitForExistence(timeout: 5))
        sportsPicker.tap()
        XCTAssertTrue(app.buttons["Football"].waitForExistence(timeout: 5))
        guard dismissPicker("Sports Feeds", in: app) else { return }

        selectDestination("Subscribed", in: app)
        XCTAssertTrue(content(for: "library", in: app).waitForExistence(timeout: 3))
    }

    func testListsSelectionAndManagementRemainReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-reset-tabs", "--ui-testing-topics-lists"]
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
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-reset-tabs", "--ui-testing-topics-lists", "--ui-testing-empty-lists"]
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

    private func selectDestination(_ label: String, in app: XCUIApplication) {
        let root: String = switch label {
        case "Finance", "Sports", "Podcasts": "Topics"
        case "Subscribed", "Following", "The Wire", "Your Circle": "News"
        case "Archive", "Read Later": "Read Later"
        case "Lists": "Lists"
        default: label
        }
        selectRoot(root, in: app)
        if label == "Lists" { return }
        selectFeed(label, in: app)
    }

    private func selectFeed(_ title: String, in app: XCUIApplication) {
        let picker = app.buttons["news-feed-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(picker))
        picker.tap()
        let option = app.buttons[title].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilHittable(option))
        option.tap()
        assertSelectedFeed(title, in: app)
    }

    private func assertSelectedFeed(_ title: String, in app: XCUIApplication) {
        let picker = app.buttons["news-feed-picker"].firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", title), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }

    private func selectRoot(_ title: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title].firstMatch
        if tab.exists && tab.isHittable { tab.tap(); return }
        if let visible = app.buttons.matching(identifier: title).allElementsBoundByIndex.first(where: { $0.isHittable }) {
            visible.tap()
            return
        }
        let toggles = ["ToggleSidebar", "ToggleSideBar", "Toggle sidebar", "Show Sidebar"]
        if let toggle = toggles.map({ app.buttons[$0].firstMatch }).first(where: { $0.exists && $0.isHittable }) { toggle.tap() }
        let button = app.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(button))
        button.tap()
    }

    private func dismissPicker(_ title: String, in app: XCUIApplication) -> Bool {
        let navigationBar = app.navigationBars[title]
        guard navigationBar.waitForExistence(timeout: 5) else {
            XCTFail("Missing picker: \(title)")
            return false
        }
        // A searchable sheet can also expose keyboard actions; dismiss its own toolbar.
        let done = navigationBar.buttons["Done"]
        guard waitUntilHittable(done) else {
            XCTFail("Unreachable picker dismissal: \(title)")
            return false
        }
        done.tap()
        guard navigationBar.waitForNonExistence(timeout: 5) else {
            XCTFail("Picker did not dismiss: \(title)")
            return false
        }
        return true
    }

    private func waitUntilHittable(_ element: XCUIElement) -> Bool {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: element)
        return XCTWaiter.wait(for: [hittable], timeout: 5) == .completed
    }

    func testWireCardsFitNarrowCanvas() {
        assertFeedCards(circle: false, largeText: false)
    }

    func testReadAgeMenuUsesAvailableDaysAndRequiresConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-reset-tabs", "--ui-testing-read-age"]
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
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-reset-tabs", "--ui-testing-feed-cards"]
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
        // Keep both representations in one live query while the menu appears.
        // Choosing a fallback before presentation can strand the wait on a stale query.
        app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@",
                        "mark-read-age-\(days)",
                        days == 7 ? "1 Week" : days == 1 ? "1 Day" : "\(days) Days")
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
