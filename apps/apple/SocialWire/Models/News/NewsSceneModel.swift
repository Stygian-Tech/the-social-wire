import Foundation
import Observation

/// Window-local navigation state with viewer-scoped top-level restoration.
@Observable
@MainActor
final class NewsSceneModel {
    private static let selectedTabKeyPrefix = "the-social-wire.news-selected-tab.v1"
    private static let routePathKeyPrefix = "the-social-wire.news-route-path.v1"

    private let defaults: UserDefaults
    private var windowID: String
    private var boundViewerDID: String?
    private var preferredUnavailableTab: NewsTab?

    private var wirePath: [NewsRoute] = []
    private var circlePath: [NewsRoute] = []
    private var libraryPath: [NewsRoute] = []
    private var savedPath: [NewsRoute] = []
    private var searchPath: [NewsRoute] = []

    private(set) var selectedTab: NewsTab = .library

    init(defaults: UserDefaults = .standard, windowID: String = "primary") {
        self.defaults = defaults
        self.windowID = windowID
    }

    func configureWindow(identifier: String) {
        guard !identifier.isEmpty, identifier != windowID else { return }
        windowID = identifier
        clearPaths()
        restorePaths()
    }

    func updateContext(viewerDID: String?, availableTabs: [NewsTab]) {
        guard let viewerDID, !viewerDID.isEmpty else {
            boundViewerDID = nil
            preferredUnavailableTab = nil
            selectedTab = NewsTab.defaultTab(in: availableTabs)
            clearPaths()
            return
        }

        if boundViewerDID != viewerDID {
            boundViewerDID = viewerDID
            clearPaths()
            let restored = defaults.string(forKey: Self.storageKey(viewerDID: viewerDID))
                .flatMap(NewsTab.init(rawValue:))
            let preferred = restored ?? .wire
            if availableTabs.contains(preferred) {
                selectedTab = preferred
                preferredUnavailableTab = nil
            } else {
                selectedTab = NewsTab.defaultTab(in: availableTabs)
                preferredUnavailableTab = preferred
            }
            restorePaths()
            return
        }

        if let preferredUnavailableTab, availableTabs.contains(preferredUnavailableTab) {
            selectedTab = preferredUnavailableTab
            self.preferredUnavailableTab = nil
            persistSelectedTab()
        } else if !availableTabs.contains(selectedTab) {
            preferredUnavailableTab = selectedTab
            selectedTab = NewsTab.defaultTab(in: availableTabs)
        }
    }

    func select(_ tab: NewsTab, availableTabs: [NewsTab]) {
        guard availableTabs.contains(tab) else { return }
        preferredUnavailableTab = nil
        selectedTab = tab
        persistSelectedTab()
    }

    func path(for tab: NewsTab) -> [NewsRoute] {
        switch tab {
        case .wire: wirePath
        case .circle: circlePath
        case .library: libraryPath
        case .saved: savedPath
        case .search: searchPath
        }
    }

    func setPath(_ path: [NewsRoute], for tab: NewsTab) {
        switch tab {
        case .wire: wirePath = path
        case .circle: circlePath = path
        case .library: libraryPath = path
        case .saved: savedPath = path
        case .search: searchPath = path
        }
        persistPath(path, for: tab)
    }

    func navigate(to route: NewsRoute, in tab: NewsTab) {
        var path = path(for: tab)
        path.append(route)
        setPath(path, for: tab)
    }

    func resetPath(for tab: NewsTab) {
        setPath([], for: tab)
    }

    static func storageKey(viewerDID: String) -> String {
        "\(selectedTabKeyPrefix).\(viewerDID)"
    }

    static func routeStorageKey(viewerDID: String, windowID: String, tab: NewsTab) -> String {
        "\(routePathKeyPrefix).\(viewerDID).\(windowID).\(tab.rawValue)"
    }

    private func clearPaths() {
        wirePath = []
        circlePath = []
        libraryPath = []
        savedPath = []
        searchPath = []
    }

    private func persistSelectedTab() {
        guard let boundViewerDID else { return }
        defaults.set(selectedTab.rawValue, forKey: Self.storageKey(viewerDID: boundViewerDID))
    }

    private func persistPath(_ path: [NewsRoute], for tab: NewsTab) {
        guard let boundViewerDID,
              let data = try? JSONEncoder().encode(path)
        else { return }
        defaults.set(
            data,
            forKey: Self.routeStorageKey(
                viewerDID: boundViewerDID,
                windowID: windowID,
                tab: tab
            )
        )
    }

    private func restorePaths() {
        guard let boundViewerDID else { return }
        for tab in NewsTab.allCases {
            let key = Self.routeStorageKey(
                viewerDID: boundViewerDID,
                windowID: windowID,
                tab: tab
            )
            guard let data = defaults.data(forKey: key),
                  let path = try? JSONDecoder().decode([NewsRoute].self, from: data)
            else { continue }
            switch tab {
            case .wire: wirePath = path
            case .circle: circlePath = path
            case .library: libraryPath = path
            case .saved: savedPath = path
            case .search: searchPath = path
            }
        }
    }
}
