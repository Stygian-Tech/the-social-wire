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
    let visibility: String?
    var isPrivate: Bool {
        visibility == "private" || URLComponents(string: audioUrl)?.path == "/v1/podcasts/media"
    }
    var permitsPublicProcessing: Bool { !isPrivate && PodcastPrivacy.permitsPublicURL(audioUrl) }
    var audioURL: String { audioUrl }
}
