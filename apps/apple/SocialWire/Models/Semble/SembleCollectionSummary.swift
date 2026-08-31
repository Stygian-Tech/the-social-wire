import Foundation

struct SembleCollectionSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    let uri: String
    let name: String
    let description: String?
    let accessType: String?
    let cardCount: Int
    let createdAt: String?
    let updatedAt: String?

    var id: String { uri }

    var ownerDID: String? {
        guard uri.hasPrefix("at://") else { return nil }
        return uri.dropFirst(5).split(separator: "/").first.map(String.init)
    }
}
