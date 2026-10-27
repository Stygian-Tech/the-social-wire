import Foundation

struct SocialAuthor: Codable, Hashable, Identifiable, Sendable {
    var id: String { did }
    let did: String
    let handle: String
    let displayName: String?
    let avatar: URL?

    var preferredName: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? handle : trimmed
    }
}
