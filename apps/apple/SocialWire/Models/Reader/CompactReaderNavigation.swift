import Foundation

/// Pure navigation decisions for the compact horizontal pager.
enum CompactReaderNavigation {
    /// Pane shown after choosing a list source on the Lists pane.
    static func paneAfterListSource(_ source: ReaderListSource) -> ReaderPane {
        switch source.navigationShape {
        case .savedLinks: .publications
        case .publicationFeed, .wire: .articles
        }
    }

    /// Pane shown after choosing a publication.
    static func paneAfterPublication(_ source: ReaderListSource) -> ReaderPane {
        source.navigationShape == .publicationFeed ? .articles : .publications
    }

    /// Pane shown after opening an article or saved link.
    static func paneAfterDetail() -> ReaderPane {
        .reader
    }

    /// Side effects when swiping between compact panes.
    struct SwipeTransition: Equatable {
        let clearsReaderDetail: Bool
        let clearsArticleSelection: Bool
        let clearsFeedState: Bool
    }

    static func swipeTransition(
        from oldPane: ReaderPane,
        to newPane: ReaderPane,
        navigationShape: ReaderNavigationShape
    ) -> SwipeTransition {
        var clearsReaderDetail = false
        var clearsArticleSelection = false
        var clearsFeedState = false

        if navigationShape.showsArticlesColumn {
            if newPane == .articles, oldPane == .reader {
                clearsReaderDetail = true
            }
            if navigationShape == .publicationFeed,
               newPane == .publications,
               oldPane == .articles {
                clearsArticleSelection = true
            }
        }

        if newPane == .lists, oldPane != .lists {
            clearsFeedState = true
        }

        return SwipeTransition(
            clearsReaderDetail: clearsReaderDetail,
            clearsArticleSelection: clearsArticleSelection,
            clearsFeedState: clearsFeedState
        )
    }

    /// Remap a pane that is absent from the new compact navigation shape.
    static func remapPaneAfterListSourceChange(
        compactPane: ReaderPane,
        newSource: ReaderListSource
    ) -> ReaderPane? {
        let panes = newSource.navigationShape.compactPanes
        guard !panes.contains(compactPane) else { return nil }
        switch newSource.navigationShape {
        case .savedLinks: return .publications
        case .publicationFeed, .wire: return .articles
        }
    }

    /// Whether an async tap handler should still animate the pager after awaiting work.
    static func shouldCompleteDeferredNavigation(
        requestedEpoch: UInt,
        currentEpoch: UInt
    ) -> Bool {
        requestedEpoch == currentEpoch
    }

    /// Normalize pane when switching between three- and four-pane compact layouts.
    static func normalizedPaneAfterLayoutChange(
        compactPane: ReaderPane,
        navigationShape: ReaderNavigationShape
    ) -> ReaderPane? {
        let panes = navigationShape.compactPanes
        guard !panes.contains(compactPane) else { return nil }
        switch navigationShape {
        case .savedLinks: return .publications
        case .publicationFeed, .wire: return .articles
        }
    }
}
