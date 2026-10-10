import Foundation

struct StandardReaderListPublication: Codable, Sendable, Equatable {
    let publicationId: String
    let title: String
    let authorDid: String
    var authorHandle: String?
    var iconUrl: String?
    var avatarUrl: String?
}
