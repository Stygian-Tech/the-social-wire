import Foundation

struct PodcastTranscriptCue: Codable, Hashable, Sendable {
    let startSeconds: Double
    let endSeconds: Double?
    let text: String
}
