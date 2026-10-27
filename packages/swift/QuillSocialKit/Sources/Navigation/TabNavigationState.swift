/// Navigation state for one tab, stored as a single path regardless of layout.
///
/// In compact width the path drives a `NavigationStack` directly. In split layouts its first
/// element is the list-column selection and the remainder is the detail column's stack. Because
/// both are projections of the same array, folding or unfolding an iPhone Duo (or resizing an
/// iPad window) keeps the user exactly where they were.
public struct TabNavigationState: Hashable, Codable, Sendable {
    public private(set) var path: [Route]

    public init(path: [Route] = []) {
        self.path = path
    }

    /// The route shown in the detail column's root in split layouts.
    public var selection: Route? {
        get { path.first }
        set { path = newValue.map { [$0] } ?? [] }
    }

    /// Routes pushed on top of the selection in the detail column.
    public var detailPath: [Route] {
        get { Array(path.dropFirst()) }
        set {
            guard let selection = path.first else {
                path = newValue
                return
            }
            path = [selection] + newValue
        }
    }

    /// Replaces the whole path. Bind a compact `NavigationStack` here.
    public mutating func setPath(_ newValue: [Route]) {
        path = newValue
    }

    /// Choose a row in the tab's root list: starts a new selection.
    public mutating func select(_ route: Route) {
        path = [route]
    }

    /// Navigate deeper from inside a destination.
    public mutating func push(_ route: Route) {
        path.append(route)
    }

    public mutating func pop() {
        _ = path.popLast()
    }

    public mutating func popToRoot() {
        path.removeAll()
    }
}
