import Foundation

struct PodcastListenerState: Codable, Sendable {
    var subscriptions: [String] = []
    var queue: [String] = []
    var progress: [String: PodcastProgress] = [:]
    var playbackSpeed: Double = 1
    var removeSilences = false
    var manualLinks: [[String: String]] = []
}
