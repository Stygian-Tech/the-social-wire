import Foundation

struct StandardReaderListSaveRecord: Codable, Sendable {
    var type = StandardReaderListContract.saveCollection
    let list: String
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case list, createdAt
    }
}
