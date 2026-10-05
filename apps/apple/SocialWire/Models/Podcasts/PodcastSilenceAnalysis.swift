import Foundation

struct PodcastSilenceAnalysis: Decodable, Sendable {
    let status: String
    let intervals: [PodcastSilenceInterval]?
    let analysisVersion: String?

    var currentIntervals: [PodcastSilenceInterval]? {
        guard analysisVersion == "v2", ["ready", "completed", "complete"].contains(status) else { return nil }
        return intervals ?? []
    }
}
