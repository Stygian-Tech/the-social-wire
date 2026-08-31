import Foundation

struct SembleCollectionItemsPage: Codable, Equatable, Sendable {
    let collection: SembleCollectionSummary
    let items: [SembleCollectionItem]
    let cursor: String?
    let membershipComplete: Bool
    let recordLinksComplete: Bool

    init(
        collection: SembleCollectionSummary,
        items: [SembleCollectionItem],
        cursor: String?,
        membershipComplete: Bool = true,
        recordLinksComplete: Bool = true
    ) {
        self.collection = collection
        self.items = items
        self.cursor = cursor
        self.membershipComplete = membershipComplete
        self.recordLinksComplete = recordLinksComplete
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collection = try container.decode(SembleCollectionSummary.self, forKey: .collection)
        items = try container.decode([SembleCollectionItem].self, forKey: .items)
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
        membershipComplete = try container.decodeIfPresent(Bool.self, forKey: .membershipComplete) ?? false
        recordLinksComplete = try container.decodeIfPresent(Bool.self, forKey: .recordLinksComplete) ?? false
    }
}
