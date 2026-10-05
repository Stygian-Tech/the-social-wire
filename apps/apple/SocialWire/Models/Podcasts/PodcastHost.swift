import Foundation

struct PodcastHost: Codable, Hashable, Sendable {
    let name: String
    let role: String?
    let imageUrl: String?
    let url: String?
}
