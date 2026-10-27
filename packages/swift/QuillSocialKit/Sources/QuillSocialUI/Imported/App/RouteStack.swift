#if os(iOS)
import Navigation
import Observation

/// One navigation stack's live state: a tab's, or a detached window's.
///
/// The stack is a reference type so container views can share it without passing bindings or
/// closures down the hierarchy, and so observation is scoped to the one stack that changed —
/// pushing in Home leaves every other tab's views untouched.
@MainActor
@Observable
final class RouteStack {
    /// The single path this stack owns. Compact stacks and split columns are both projections
    /// of it, so folding an iPhone Duo or resizing an iPad window keeps the user's place.
    var state: TabNavigationState

    init(state: TabNavigationState = TabNavigationState()) {
        self.state = state
    }

    /// Key-path projections, so views bind with `$stack.path` rather than building a
    /// closure-backed `Binding` on every body evaluation.
    var path: [Route] {
        get { state.path }
        set { state.setPath(newValue) }
    }

    var selection: Route? {
        get { state.selection }
        set { state.selection = newValue }
    }

    var detailPath: [Route] {
        get { state.detailPath }
        set { state.detailPath = newValue }
    }

    /// Choose a row in a root list: starts a new selection.
    func select(_ route: Route) {
        state.select(route)
    }

    /// Navigate deeper from inside a destination.
    func push(_ route: Route) {
        state.push(route)
    }

    func popToRoot() {
        state.popToRoot()
    }
}

#endif
