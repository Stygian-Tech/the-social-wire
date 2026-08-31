import Foundation

struct SembleCollectionLinkRecord: Codable, Equatable, Sendable {
    let type: String
    let collection: StrongRef
    let card: StrongRef
    let addedBy: String
    let addedAt: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case collection
        case card
        case addedBy
        case addedAt
        case createdAt
    }
}
