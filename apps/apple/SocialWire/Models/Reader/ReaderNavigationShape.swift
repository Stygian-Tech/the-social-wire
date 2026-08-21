import Foundation

enum ReaderNavigationShape: Equatable {
    /// Lists → saved links → reader.
    case savedLinks
    /// Lists → publications → articles → reader.
    case publicationFeed
    /// Lists → articles → reader.
    case wire

    var compactPanes: [ReaderPane] {
        switch self {
        case .savedLinks: [.lists, .publications, .reader]
        case .publicationFeed: [.lists, .publications, .articles, .reader]
        case .wire: [.lists, .articles, .reader]
        }
    }

    var showsArticlesColumn: Bool {
        self != .savedLinks
    }
}
