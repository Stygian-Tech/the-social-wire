import Foundation

/// Ownership of one entry-list request, including repeated visits to the same scope.
struct ReaderFeedRequestContext {
    let revision: Int
    let viewerDID: String?
    let selection: FeedSelection
    let filter: ReaderFilter
}
