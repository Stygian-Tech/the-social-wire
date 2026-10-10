import Foundation

struct StandardReaderList: Codable, Identifiable, Sendable, Equatable {
    let uri: String
    var name: String
    var description: String?
    let creatorDid: String
    var publications: [String]
    var publicationDetails: [StandardReaderListPublication]?
    var users: [String]
    var owned: Bool
    var saved: Bool
    var id: String { uri }
}
