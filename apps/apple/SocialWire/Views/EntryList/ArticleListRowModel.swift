import Foundation

struct ArticleListRowModel {
    let title: String
    let summary: String?
    let subtitle: String
    let thumbnailURLs: [URL]
    let publication: SavedLinkPublicationChipModel?
    let reason: String?
    let reasonAccessibilityLabel: String?
    let tags: [String]
    let isRead: Bool
    let showsReadState: Bool
}
