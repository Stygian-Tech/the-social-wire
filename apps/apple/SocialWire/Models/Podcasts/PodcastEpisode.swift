import Foundation

struct PodcastEpisode: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let showId: String
    let title: String
    let description: String?
    let publishedAt: String
    let audioUrl: String
    let audioMimeType: String?
    let durationSeconds: Double?
    let artworkUrl: String?
    let guid: String?
    let sourceUri: String?
    let transcripts: [PodcastTranscriptReference]
    var audioURL: String { audioUrl }
}
