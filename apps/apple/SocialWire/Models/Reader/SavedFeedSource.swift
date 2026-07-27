import Foundation

struct SavedFeedSource: Identifiable, Equatable, Sendable {
    let id: String
    let model: SavedLinkPublicationChipModel
    let count: Int
}
