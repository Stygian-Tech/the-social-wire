import Foundation

struct PodcastProgress: Codable, Sendable {
    let positionSeconds: Double
    let updatedAt: String
    let completed: Bool
}
