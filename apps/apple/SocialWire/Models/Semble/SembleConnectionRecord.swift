import Foundation

struct SembleConnectionRecord: Codable, Equatable, Sendable {
    let type: String
    let source: String
    let target: String
    let connectionType: String?
    let note: String?
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case source
        case target
        case connectionType
        case note
        case createdAt
        case updatedAt
    }
}
