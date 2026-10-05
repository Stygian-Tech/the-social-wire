import Foundation

struct PodcastClip: Codable, Identifiable, Sendable {
    let id: String
    let episodeId: String
    let sourceUri: String?
    let startSeconds: Double
    let endSeconds: Double
    let title: String
    let status: String
    let audioUrl: String?
    let videoUrl: String?
    let publicAudioUrl: String?
    let publicVideoUrl: String?
    let publishedUri: String?
    let createdAt: String
}
