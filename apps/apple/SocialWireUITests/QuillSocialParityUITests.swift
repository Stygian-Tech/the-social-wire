import XCTest
import UIKit

@MainActor
final class QuillSocialParityUITests: XCTestCase {
    private func launch(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-quill-social", "--ui-testing-reset-tabs"] + additionalArguments
        app.launch()
        if app.tabBars.buttons["Social"].waitForExistence(timeout: 5) {
            app.tabBars.buttons["Social"].tap()
        } else {
            let home = app.buttons["news-social-timeline"]
            reveal(home, in: app)
            home.tap()
        }
        XCTAssertTrue(post("Quill Fixture Root", in: app).waitForExistence(timeout: 10))
        return app
    }

    func testLongProfileRemainsResponsiveAfterScrolling() {
        assertProfileRemainsResponsiveAfterScrolling(actor: "fixtureauthor")
    }

    func testOwnProfileRemainsResponsiveAfterScrolling() {
        assertProfileRemainsResponsiveAfterScrolling(actor: "fixtureviewer")
    }

    private func assertProfileRemainsResponsiveAfterScrolling(actor: String) {
        let app = launch(additionalArguments: ["--ui-testing-long-profile"])
        let avatar = app.buttons["Open @did:plc:\(actor) Profile"].firstMatch
        reveal(avatar, in: app)
        avatar.tap()
        let scroll = app.scrollViews["social-profile-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let identity = app.descendants(matching: .any)["social-profile-sticky-identity"]
        XCTAssertFalse(identity.isHittable)
        for _ in 0..<2 {
            scroll.swipeUp()
            scroll.swipeUp()
            XCTAssertTrue(identity.waitForExistence(timeout: 5))
            XCTAssertTrue(identity.isHittable)
            let picture = app.buttons["Profile picture"].firstMatch
            for _ in 0..<4 {
                if picture.isHittable && !identity.isHittable { break }
                scroll.swipeDown()
            }
            XCTAssertTrue(picture.isHittable)
            XCTAssertFalse(identity.isHittable)
        }
        scroll.swipeUp()
        scroll.swipeUp()
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        XCTAssertTrue(identity.isHittable)
        let account = app.buttons["social-open-account"].firstMatch
        XCTAssertTrue(account.isHittable)
        account.tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        app.navigationBars["Profile"].buttons["Done"].tap()
        XCTAssertTrue(scroll.exists)
    }

    func testAccountAndLogoutRemainReachableFromSocialProfile() {
        let app = launch()
        let account = app.buttons["social-open-account"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        let logout = app.buttons["account-log-out"]
        reveal(logout, in: app)
        XCTAssertTrue(logout.isHittable)
        app.navigationBars["Profile"].buttons["Done"].tap()

        let ownAvatar = app.buttons["Open @did:plc:fixtureviewer Profile"].firstMatch
        reveal(ownAvatar, in: app)
        ownAvatar.tap()
        XCTAssertTrue(app.buttons["news-show-sidebar"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["news-show-sidebar"].firstMatch.isHittable)
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertTrue(account.isHittable)
        account.tap()
        reveal(logout, in: app)
        XCTAssertTrue(logout.isHittable)
        logout.tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForNonExistence(timeout: 5))
    }

    func testRegularWidthUsesSidebarWithoutPhoneTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-news-shell", "--ui-testing-quill-social",
                               "--ui-testing-reset-tabs", "--ui-testing-regular-window"]
        app.launch()
        let sidebar = app.descendants(matching: .any)["news-sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        let sidebarColumn = app.descendants(matching: .any)["news-persistent-sidebar"].firstMatch
        if UIDevice.current.userInterfaceIdiom != .pad {
            XCTAssertTrue(sidebarColumn.exists)
            XCTAssertGreaterThanOrEqual(sidebar.frame.width, sidebarColumn.frame.width - 2,
                                        "The sidebar must not reserve a second trailing toolbar gutter")
        }
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["Browse"].exists)
        let home = app.buttons["news-social-timeline"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(home.frame.width, sidebar.frame.width * 0.8)
        home.tap()
        XCTAssertTrue(post("Quill Fixture Root", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(sidebar.exists)
        app.buttons["news-show-sidebar"].firstMatch.tap()
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(post("Quill Fixture Root", in: app).exists)
        app.buttons["news-show-sidebar"].firstMatch.tap()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertTrue(post("Quill Fixture Root", in: app).exists)
        app.buttons["news-social-notifications"].tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        home.tap()
        XCTAssertTrue(post("Quill Fixture Root", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["Browse"].exists)
    }

    func testQuillTimelineIncludesStoriesFeedGeneratorsAndRepostAttribution() {
        let app = launch()
        XCTAssertTrue(app.buttons["New Post"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Fixture Feed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Story by'")).firstMatch.exists)
        XCTAssertTrue(post("Quill Fixture Reply", in: app).exists)
        let repost = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Reposted by'")).firstMatch
        reveal(repost, in: app)
        XCTAssertTrue(repost.exists)
        app.buttons["Fixture Feed"].tap()
        XCTAssertEqual(app.buttons["Fixture Feed"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["Following"].value as? String, "Not Selected")
        XCTAssertTrue(post("Quill Fixture Root", in: app).waitForExistence(timeout: 5))
        app.buttons["Following"].tap()
        XCTAssertEqual(app.buttons["Following"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["Fixture Feed"].value as? String, "Not Selected")
    }

    func testQuillThreadRetainsNestedReplies() {
        let app = launch()
        post("Quill Fixture Root", in: app).tap()
        let nested = post("Quill Fixture Nested Reply", in: app)
        reveal(nested, in: app)
        XCTAssertTrue(nested.exists)
        XCTAssertTrue(post("Quill Fixture Reply", in: app).exists)
    }

    func testFloatingComposerUsesQuillEditorAndReturnsToFeed() {
        let app = launch()
        app.buttons["New Post"].tap()
        XCTAssertTrue(app.navigationBars["New Post"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        app.textViews.firstMatch.tap()
        app.textViews.firstMatch.typeText("Native Quill Composer")
        XCTAssertTrue(app.navigationBars.buttons["Post"].isEnabled)
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(post("Quill Fixture Root", in: app).waitForExistence(timeout: 5))
    }

    func testSidebarOpensAtLeadingEdgeAndReturnsToTheSameFeed() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone drawer navigation")
        let app = launch()
        app.buttons["news-show-sidebar"].firstMatch.tap()
        let drawer = app.descendants(matching: .any)["news-sidebar"].firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        XCTAssertEqual(drawer.frame.minX, app.frame.minX, accuracy: 2)
        XCTAssertLessThan(drawer.frame.width, app.frame.width * 0.95)
        XCTAssertGreaterThan(drawer.frame.height, app.frame.height * 0.5)
        XCTAssertLessThan(drawer.frame.minY, app.frame.height * 0.3)
        XCTAssertFalse(app.buttons["Done"].exists)
        XCTAssertTrue(app.buttons["news-hide-sidebar"].exists)
        app.buttons["news-hide-sidebar"].tap()
        XCTAssertTrue(post("Quill Fixture Root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Social"].isSelected)
        app.buttons["news-show-sidebar"].firstMatch.tap()
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        app.buttons["news-social-notifications"].tap()
        XCTAssertFalse(drawer.exists)
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Social"].isSelected)
    }

    func testComposerKeepsCounterAndToolsAboveKeyboardForLongThreadDrafts() {
        let app = launch()
        app.buttons["New Post"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let draft = Array(repeating: "A line of draft text.", count: 12).joined(separator: "\n")
        editor.typeText(draft)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(editor.frame.height, 180)
        assertComposerControlsVisible(in: app, remaining: 300 - draft.count)
        app.buttons["composer-add-post"].tap()
        let second = app.textViews.matching(NSPredicate(format: "label == 'Add another post'")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.typeText("Second draft")
        assertComposerControlsVisible(in: app, remaining: 288)
        app.navigationBars.buttons["Cancel"].tap()
    }

    func testComposerControlsRemainReachableInLandscape() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone landscape keyboard")
        let app = launch()
        app.buttons["New Post"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Landscape draft")
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            if #unavailable(iOS 26) {
                XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            }
            editor.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            assertComposerControlsVisible(in: app, remaining: 285)
        }
        app.navigationBars.buttons["Cancel"].tap()
    }

    func testNotificationsShortcutOpensTheSharedNotificationsView() {
        let app = launch()
        let notifications = app.buttons["social-open-notifications"]
        XCTAssertTrue(notifications.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Your Profile"].exists)
        notifications.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["social-open-notifications"].exists)
        if app.tabBars.firstMatch.exists {
            XCTAssertTrue(app.tabBars.buttons["Social"].isSelected)
            app.tabBars.buttons["Social"].tap()
            XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["New Post"].isHittable)
        }
    }

    func testSocialTabReturnsHomeFromAProfile() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone tab navigation")
        let app = launch()
        let avatar = app.buttons["Open @did:plc:fixtureauthor Profile"].firstMatch
        reveal(avatar, in: app)
        avatar.tap()
        XCTAssertTrue(app.staticTexts["Fixture Author"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["New Post"].isHittable)
        app.tabBars.buttons["Social"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["New Post"].isHittable)
    }

    func testNotificationsShowReactionSubjectsAndReplyQuoteContext() {
        let app = launch()
        app.buttons["social-open-notifications"].tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        for (reason, content) in [("like", "Quill Fixture Root"), ("repost", "Quill Fixture Root"),
                                  ("reply", "Quill Fixture Reply"), ("quote", "Quill Fixture Quote")] {
            let preview = app.buttons["notification-post-\(reason)"]
            reveal(preview, in: app)
            XCTAssertTrue(preview.waitForExistence(timeout: 5), reason)
            XCTAssertTrue(preview.label.contains(content), "\(reason) should show its post")
            if reason == "reply" || reason == "quote" {
                let original = app.buttons["notification-context-\(reason)"]
                reveal(original, in: app)
                XCTAssertTrue(original.waitForExistence(timeout: 5), "\(reason) should show the original post")
                XCTAssertTrue(original.label.contains("Quill Fixture Root"))
            }
        }
        let original = app.buttons["notification-context-quote"]
        reveal(original, in: app)
        original.tap()
        XCTAssertTrue(app.navigationBars.buttons["Notifications"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(post("Quill Fixture Root", in: app).waitForExistence(timeout: 5))
    }

    func testNotificationAvatarStackOpensQuillsPeopleSheet() {
        let app = launch()
        app.buttons["social-open-notifications"].tap()
        let first = app.buttons["social-notification-avatar-like-did:plc:fixturereposter"]
        let second = app.buttons["social-notification-avatar-like-did:plc:fixtureauthor"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertLessThan(first.frame.midX, second.frame.midX)
        XCTAssertEqual(first.frame.midY, second.frame.midY, accuracy: 1)
        let people = app.buttons["social-notification-actors-like"]
        XCTAssertTrue(people.label.contains("Fixture Reposter"))
        XCTAssertTrue(people.label.contains("liked your post"))
        people.tap()
        XCTAssertTrue(app.navigationBars["People"].waitForExistence(timeout: 5))
        let reposter = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "@reposter.fixture.test")).firstMatch
        let author = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "@fixture.test")).firstMatch
        XCTAssertTrue(reposter.exists)
        XCTAssertTrue(author.exists)
        author.tap()
        XCTAssertTrue(app.staticTexts["Fixture Author"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["People"].exists)
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons["Social"].tap()
            XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        }
    }

    func testThemeColorSelectionPersistsAcrossLaunches() {
        let app = launch()
        let picker = openThemeColorPicker(in: app)
        let previous = selectedThemeColor(picker)
        picker.tap()
        app.buttons["Green"].tap()
        XCTAssertEqual(selectedThemeColor(picker), "Green")
        app.terminate()
        app.launch()
        if app.tabBars.buttons["Social"].waitForExistence(timeout: 5) {
            app.tabBars.buttons["Social"].tap()
        }
        let restored = openThemeColorPicker(in: app)
        XCTAssertEqual(selectedThemeColor(restored), "Green")
        restored.tap()
        app.buttons[previous].tap()
    }

    func testSidebarAndPostAvatarsOpenTheSameSocialProfileAndSettings() {
        let app = launch()
        let sidebarThemePicker = openThemeColorPicker(in: app)
        let expectedColor = selectedThemeColor(sidebarThemePicker)
        XCTAssertTrue(app.buttons["Social Settings"].exists)
        app.terminate()

        let relaunched = launch()
        let ownAvatar = relaunched.buttons["Open @did:plc:fixtureviewer Profile"].firstMatch
        reveal(ownAvatar, in: relaunched)
        ownAvatar.tap()
        assertCurrentSocialProfile(in: relaunched)
        openAccountSettingsFromSocialProfile(in: relaunched)
        let socialThemePicker = relaunched.descendants(matching: .any)["settings-theme-color"].firstMatch
        XCTAssertTrue(socialThemePicker.waitForExistence(timeout: 5))
        XCTAssertEqual(selectedThemeColor(socialThemePicker), expectedColor)
        relaunched.buttons["Social Settings"].tap()
        XCTAssertTrue(relaunched.buttons["Content Provider"].waitForExistence(timeout: 5))
        XCTAssertTrue(relaunched.buttons["Moderation"].exists)
        XCTAssertTrue(relaunched.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Trusted Verifiers'")).firstMatch.exists)
    }

    private func assertCurrentSocialProfile(in app: XCUIApplication,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars.buttons["Settings"].firstMatch.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(app.staticTexts["Fixture Viewer"].firstMatch.exists, file: file, line: line)
        XCTAssertFalse(app.navigationBars["Profile"].exists, "Avatar should open the Social profile, not account settings", file: file, line: line)
        XCTAssertFalse(app.buttons["Send Feedback"].exists, file: file, line: line)
    }

    private func openAccountSettingsFromSocialProfile(in app: XCUIApplication) {
        app.navigationBars.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Send Feedback"].exists)
        app.buttons["account-open-settings"].tap()
    }

    private func selectedThemeColor(_ picker: XCUIElement,
                                    file: StaticString = #filePath, line: UInt = #line) -> String {
        let colors = ["Red", "Orange", "Yellow", "Green", "Mint", "Teal", "Cyan", "Blue", "Indigo", "Purple", "Pink"]
        // Native menu Pickers expose the selection as a value on iOS 18 and
        // include it in their accessibility label on newer system versions.
        if let value = picker.value as? String, colors.contains(value) { return value }
        let prefix = "Theme Color, "
        if picker.label.hasPrefix(prefix) {
            let selection = String(picker.label.dropFirst(prefix.count))
            if colors.contains(selection) { return selection }
        }
        XCTFail("Theme Color picker did not expose a known selection: label=\(picker.label), value=\(String(describing: picker.value))",
                file: file, line: line)
        return "Indigo"
    }

    private func openThemeColorPicker(in app: XCUIApplication) -> XCUIElement {
        if app.tabBars.buttons["Browse"].exists {
            app.tabBars.buttons["Browse"].tap()
        }
        let profile = app.buttons["Profile"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()
        assertCurrentSocialProfile(in: app)
        openAccountSettingsFromSocialProfile(in: app)
        let picker = app.descendants(matching: .any)["settings-theme-color"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        return picker
    }

    private func assertComposerControlsVisible(in app: XCUIApplication, remaining: Int,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = app.keyboards.firstMatch
        for id in ["composer-photos", "composer-files", "composer-gif", "composer-add-post", "composer-character-count"] {
            let control = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(control.exists, id, file: file, line: line)
            XCTAssertTrue(control.isHittable, id, file: file, line: line)
            if keyboard.exists && keyboard.frame.width > app.frame.width * 0.7 {
                XCTAssertLessThanOrEqual(control.frame.maxY, keyboard.frame.minY + 2, id, file: file, line: line)
            }
        }
        let counter = app.descendants(matching: .any)["composer-character-count"].firstMatch
        XCTAssertEqual(counter.value as? String, String(remaining), file: file, line: line)
    }

    private func post(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists)
    }
}
