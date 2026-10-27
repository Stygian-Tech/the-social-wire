import Foundation
import Testing
@testable import SocialWire

@Suite("Pinned section navigation")
@MainActor
struct NewsSectionPreferencesTests {
    @Test("Unread Social notifications badge the pinned Social tab without duplicating Browse")
    func pinnedSocialBadge() {
        let preferences = NewsSectionPreferences(pinnedSections: [.social, .feeds])
        #expect(preferences.badgeCount(for: .section(.social), unreadSocialNotifications: 12) == 12)
        #expect(preferences.badgeCount(for: .browse, unreadSocialNotifications: 12) == 0)
        #expect(preferences.badgeCount(for: .section(.feeds), unreadSocialNotifications: 12) == 0)
    }

    @Test("Browse inherits the badge when Social is unpinned and zero hides it")
    func unpinnedSocialBadge() {
        let preferences = NewsSectionPreferences(pinnedSections: [.feeds])
        #expect(preferences.badgeCount(for: .browse, unreadSocialNotifications: 12) == 12)
        #expect(preferences.badgeCount(for: .browse, unreadSocialNotifications: 0) == 0)
        #expect(preferences.badgeCount(for: .browse, unreadSocialNotifications: -1) == 0)
    }

    @Test("A fifth favorite is rejected so Browse always fits in the native tab bar")
    func pinLimit() {
        var preferences = NewsSectionPreferences()
        let original = preferences.pinnedSections
        preferences.setPinned(true, section: .media)
        #expect(preferences.pinnedSections == original)

        preferences.setPinned(false, section: .topics)
        preferences.setPinned(true, section: .media)
        #expect(preferences.pinnedSections.count == 4)
        #expect(preferences.pinnedSections.last == .media)
        #expect(!preferences.pinnedSections.contains(.topics))
    }

    @Test("Restoration deduplicates and caps pins while preserving order")
    func normalizedRestoration() {
        let preferences = NewsSectionPreferences(
            pinnedSections: [.social, .social, .media, .feeds, .lists, .topics, .readLater]
        )
        #expect(preferences.pinnedSections == [.social, .media, .feeds, .lists])
    }

    @Test("Pin order and an intentionally empty bar persist independently per viewer")
    func viewerPersistence() throws {
        let suite = "NewsSectionPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let reordered = NewsSectionPreferences(pinnedSections: [.media, .social, .readLater])
        reordered.save(viewerDID: "alice", defaults: defaults)
        NewsSectionPreferences(pinnedSections: []).save(viewerDID: "bob", defaults: defaults)

        #expect(NewsSectionPreferences.load(viewerDID: "alice", defaults: defaults) == reordered)
        #expect(NewsSectionPreferences.load(viewerDID: "bob", defaults: defaults).pinnedSections.isEmpty)
        #expect(NewsSectionPreferences.load(viewerDID: "new-viewer", defaults: defaults) == NewsSectionPreferences())
    }

    @Test("Unpinning every section does not remove any sidebar destination")
    func sidebarIndependence() {
        var preferences = NewsSectionPreferences()
        for section in NewsRootSection.allCases {
            preferences.setPinned(false, section: section)
        }
        #expect(preferences.pinnedSections.isEmpty)
        #expect(Set(NewsRootSection.allCases) == [.readLater, .feeds, .topics, .lists, .social, .media])
    }

    @Test("Sidebar destinations route through Browse unless pinned")
    func browseRouting() {
        let preferences = NewsSectionPreferences(pinnedSections: [.social, .feeds])
        #expect(preferences.tab(for: .social) == .section(.social))
        #expect(preferences.tab(for: .lists) == .browse)
        #expect(preferences.tab(for: .media) == .browse)
        let empty = NewsSectionPreferences(pinnedSections: [])
        #expect(NewsRootSection.allCases.allSatisfy { empty.tab(for: $0) == .browse })
    }

    @Test("Existing five-shortcut settings migrate in order and leave all sections browsable")
    func legacyFivePins() {
        let preferences = NewsSectionPreferences(pinnedSections: [.readLater, .feeds, .topics, .lists, .media])
        #expect(preferences.pinnedSections == [.readLater, .feeds, .topics, .lists])
        #expect(preferences.tab(for: .media) == .browse)
        #expect(preferences.tab(for: .social) == .browse)
    }
}
