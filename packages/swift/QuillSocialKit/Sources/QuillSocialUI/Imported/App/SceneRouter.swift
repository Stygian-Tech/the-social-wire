#if os(iOS)
import Navigation
import Observation

/// Owns one window's navigation.
///
/// Each tab gets its own `RouteStack`, created once and kept for the life of the window. That
/// keeps observation per-tab: a push in Home doesn't invalidate the shell or the other tabs.
/// `NavigationState` remains the value snapshot used for scene storage.
@MainActor
@Observable
final class SceneRouter {
    /// Backing store for `selectedTab`, which layers the pop-to-root behaviour on top.
    private var tabSelection: AppTab

    /// One stack per tab, in `AppTab.allCases` order.
    let tabs: [TabStack]

    init(state: NavigationState = NavigationState()) {
        tabSelection = state.selectedTab
        tabs = AppTab.allCases.map { TabStack(tab: $0, stack: RouteStack(state: state[$0])) }
    }

    /// Bind a `TabView` here: re-selecting the current tab pops it to its root, matching the
    /// system tab bar.
    var selectedTab: AppTab {
        get { tabSelection }
        set {
            if newValue == tabSelection {
                stack(for: newValue)?.popToRoot()
            } else {
                tabSelection = newValue
            }
        }
    }

    func stack(for tab: AppTab) -> RouteStack? {
        tabs.first { $0.tab == tab }?.stack
    }

    /// Switches to a tab and shows a route at the root of it. Used by sidebar destinations such
    /// as pinned feeds, which belong to Home but are reachable from anywhere in the sidebar.
    func show(_ route: Route, in tab: AppTab) {
        tabSelection = tab
        stack(for: tab)?.select(route)
    }

    /// Whether a route is currently the root of a tab, for sidebar selection state.
    func isShowing(_ route: Route, in tab: AppTab) -> Bool {
        tabSelection == tab && stack(for: tab)?.selection == route
    }

    /// A value snapshot of the whole window, for persisting with scene storage.
    var snapshot: NavigationState {
        var state = NavigationState(selectedTab: tabSelection)
        for entry in tabs {
            state[entry.tab] = entry.stack.state
        }
        return state
    }

    func restore(from state: NavigationState) {
        tabSelection = state.selectedTab
        for entry in tabs {
            // Identical values don't notify, so tabs that didn't change stay untouched.
            entry.stack.state = state[entry.tab]
        }
    }

    /// Opens a route from outside the current flow (deep link, notification, "Open in App").
    func open(_ route: Route) {
        var state = snapshot
        state.open(route)
        restore(from: state)
    }
}

#endif
