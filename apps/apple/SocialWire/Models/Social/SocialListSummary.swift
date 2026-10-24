import Foundation

struct SocialListSummary: Hashable, Identifiable, Sendable {
    var id: String { uri }
    let uri: String
    let cid: String
    let name: String
    let description: String
    let avatar: URL?
    let creator: SocialAuthor
    let itemCount: Int
}
