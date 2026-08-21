import Foundation

/// Compact-width horizontal pager.
/// Subscribed/Following: lists → publications → articles → reader.
/// Read Later/Archive: lists → saved links → reader.
enum ReaderPane: Int, Hashable, CaseIterable {
    case lists = 0
    case publications = 1
    case articles = 2
    case reader = 3

    /// Contiguous `TabView` page index for the active reader shape.
    func compactTabTag(navigationShape: ReaderNavigationShape) -> Int? {
        navigationShape.compactPanes.firstIndex(of: self)
    }

    static func fromCompactTabTag(_ tag: Int, navigationShape: ReaderNavigationShape) -> ReaderPane {
        let panes = navigationShape.compactPanes
        guard panes.indices.contains(tag) else { return panes.last ?? .lists }
        return panes[tag]
    }
}
