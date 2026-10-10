import Foundation

struct StandardReaderListRecord: Codable, Sendable {
    var type = StandardReaderListContract.collection
    let name: String
    let description: String?
    let publications: [String]
    let users: [String]?
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case name, description, publications, users, createdAt
    }
}
