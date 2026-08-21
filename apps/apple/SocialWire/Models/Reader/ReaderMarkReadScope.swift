import Foundation

/// Scope for the reader shell mark-read toolbar action (pane / selection aware).
enum ReaderMarkReadScope: Equatable {
    case allLists
    case list(ReaderListSource)
    case folder(folderRkey: String)
    case publication(publicationId: String)
    case entry(entryId: String)
    case unavailable

    static func selectedFeed(_ selection: FeedSelection) -> ReaderMarkReadScope {
        switch selection {
        case .topLevel(let source):
            source.supportsReadState ? .list(source) : .unavailable
        case .folder(let folderRkey):
            .folder(folderRkey: folderRkey)
        case .publication(let publicationId):
            .publication(publicationId: publicationId)
        case .savedSource:
            .unavailable
        }
    }
}
