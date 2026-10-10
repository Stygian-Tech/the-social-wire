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
    let showArtworkUrl: String?
    let guid: String?
    let sourceUri: String?
    let transcripts: [PodcastTranscriptReference]
    let visibility: String?
    let chapters: [PodcastChapter]?
    func activeChapter(at position: Double) -> PodcastChapter? {
        (chapters ?? []).filter { $0.startSeconds.isFinite && $0.startSeconds >= 0 && $0.startSeconds <= position }
            .max { $0.startSeconds < $1.startSeconds }
    }
    var isPrivate: Bool {
        visibility == "private" || URLComponents(string: audioUrl)?.path == "/v1/podcasts/media"
    }
    var permitsPublicProcessing: Bool {
        guard !isPrivate, let components = URLComponents(string: audioUrl) else { return false }
        return components.scheme == "https" && components.host != nil
            && components.user == nil && components.password == nil
    }
    var audioURL: String { audioUrl }
}
