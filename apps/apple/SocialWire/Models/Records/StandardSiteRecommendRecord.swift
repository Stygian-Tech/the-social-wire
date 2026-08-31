import Foundation

struct StandardSiteRecommendRecord: Codable, Equatable, Sendable {
    let type: String
    let document: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case document
        case createdAt
    }
}
