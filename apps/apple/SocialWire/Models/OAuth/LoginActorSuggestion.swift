import Foundation

struct LoginActorSuggestion: Codable, Identifiable, Equatable, Sendable {
    let did: String
    let handle: String
    let displayName: String?
    let avatar: String?

    var id: String { did }
}
