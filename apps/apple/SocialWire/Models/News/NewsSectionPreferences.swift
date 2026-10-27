import Foundation

/// Device-local shortcuts, independent of section availability or the active destination.
struct NewsSectionPreferences: Equatable {
    static let maximumPinnedSections = 4
    static let defaultSections: [NewsRootSection] = [.readLater, .feeds, .social, .topics]

    private(set) var pinnedSections: [NewsRootSection]

    init(pinnedSections: [NewsRootSection] = Self.defaultSections) {
        var seen: Set<NewsRootSection> = []
        self.pinnedSections = Array(pinnedSections.filter { seen.insert($0).inserted }
            .prefix(Self.maximumPinnedSections))
    }

    mutating func setPinned(_ pinned: Bool, section: NewsRootSection) {
        if !pinned {
            pinnedSections.removeAll { $0 == section }
        } else if !pinnedSections.contains(section), pinnedSections.count < Self.maximumPinnedSections {
            pinnedSections.append(section)
        }
    }

    func tab(for section: NewsRootSection) -> NewsPhoneTab {
        pinnedSections.contains(section) ? .section(section) : .browse
    }

    /// Unpinned Social activity remains discoverable through the permanent Browse tab.
    func badgeCount(for tab: NewsPhoneTab, unreadSocialNotifications: Int) -> Int {
        tab == self.tab(for: .social) ? max(0, unreadSocialNotifications) : 0
    }

    static func load(viewerDID: String?, defaults: UserDefaults = .standard) -> Self {
        guard let stored = defaults.stringArray(forKey: storageKey(viewerDID)) else { return Self() }
        return Self(pinnedSections: stored.compactMap(NewsRootSection.init(rawValue:)))
    }

    func save(viewerDID: String?, defaults: UserDefaults = .standard) {
        defaults.set(pinnedSections.map(\.rawValue), forKey: Self.storageKey(viewerDID))
    }

    private static func storageKey(_ viewerDID: String?) -> String {
        "the-social-wire.pinned-sections.v1.\(viewerDID ?? "signed-out")"
    }
}
