import Foundation

struct WireArticleFeedbackRecord: Codable, Equatable, Sendable {
    let type: String
    let canonicalUrl: String
    let subject: String?
    let value: WireArticleFeedbackValue
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case canonicalUrl
        case subject
        case value
        case createdAt
        case updatedAt
    }
}
