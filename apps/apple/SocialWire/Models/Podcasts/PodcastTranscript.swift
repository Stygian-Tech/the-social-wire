import Foundation

struct PodcastTranscript: Codable, Sendable {
    let url: String
    let type: String
    let language: String?
    let text: String?
    let cues: [PodcastTranscriptCue]
}
