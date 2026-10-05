import Foundation

struct PodcastTranscriptReference: Codable, Hashable, Sendable {
    let url: String
    let type: String
    let language: String?
}
