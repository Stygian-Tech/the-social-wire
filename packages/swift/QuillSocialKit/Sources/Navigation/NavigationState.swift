/// All navigation state for one scene (window). Codable so it can be persisted with scene storage
/// and restored after the app is terminated or a window is reopened.
public struct NavigationState: Hashable, Codable, Sendable {
    public var selectedTab: AppTab
    private var tabs: [AppTab: TabNavigationState]

    public init(selectedTab: AppTab = .home) {
        self.selectedTab = selectedTab
        self.tabs = [:]
    }

    public subscript(tab: AppTab) -> TabNavigationState {
        get { tabs[tab] ?? TabNavigationState() }
        set { tabs[tab] = newValue }
    }

    /// Opens a route from outside the current flow (deep link, notification, "Open in App").
    /// Conversations go to the Chat tab; everything else is pushed onto the current tab.
    public mutating func open(_ route: Route) {
        if case .conversation = route {
            selectedTab = .chat
            self[.chat].select(route)
        } else {
            self[selectedTab].push(route)
        }
    }

    /// Re-selecting the current tab pops it to its root, matching system tab bar behaviour.
    public mutating func reselect(_ tab: AppTab) {
        if tab == selectedTab {
            self[tab].popToRoot()
        } else {
            selectedTab = tab
        }
    }
}
