import Foundation

struct SembleCollectionLinkRemovalRecord: Codable, Equatable, Sendable {
    let type: String
    let collection: StrongRef
    let removedLink: StrongRef
    let removedAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case collection
        case removedLink
        case removedAt
    }
}
