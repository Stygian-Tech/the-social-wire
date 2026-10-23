import Foundation

enum SocialRoute: Hashable, Sendable {
    case post(uri: String)
    case profile(did: String)
    case feed(uri: String, name: String)
    case list(uri: String, name: String)
    case conversation(id: String)
    case compose(replyTo: SocialPostReference?, quote: SocialPostReference?)
}

struct SocialPostReference: Hashable, Codable, Sendable {
    let uri: String
    let cid: String
}
