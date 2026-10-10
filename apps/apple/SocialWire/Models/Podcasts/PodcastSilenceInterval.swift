import Foundation

struct PodcastSilenceInterval: Codable, Sendable {
    let start: Double
    let end: Double

    func destination(at position: Double) -> Double? {
        guard start.isFinite, end.isFinite, position.isFinite, start >= 0, end > start,
              position >= start, position < end - 0.05 else { return nil }
        return end
    }
}
