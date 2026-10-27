#if os(iOS)
import Navigation
import SwiftUI

/// How a `RouteLink` navigates in its container: starting a new selection from a tab's root
/// list, or pushing from inside a destination. Injected by the container, so rows never need
/// to know the layout.
///
/// This deliberately stores no closure. SwiftUI can't compare function values, so a closure in
/// the environment — even wrapped in a struct — invalidates every reader on every body
/// evaluation of the writer. Storing the stack and the mode instead keeps the value comparable.
struct RouteNavigator {
    enum Mode: Hashable {
        /// Replace the container's path, as choosing a row in a root list does.
        case select
        /// Push onto the container's path, as navigating from inside a destination does.
        case push
    }

    let stack: RouteStack
    let mode: Mode

    @MainActor
    func callAsFunction(_ route: Route) {
        switch mode {
        case .select: stack.select(route)
        case .push: stack.push(route)
        }
    }
}

extension RouteNavigator: Equatable {
    static func == (lhs: RouteNavigator, rhs: RouteNavigator) -> Bool {
        lhs.stack === rhs.stack && lhs.mode == rhs.mode
    }
}

extension EnvironmentValues {
    /// `nil` in containers that don't navigate, which also keeps the default value stable.
    @Entry var routeNavigator: RouteNavigator?
}

#endif
