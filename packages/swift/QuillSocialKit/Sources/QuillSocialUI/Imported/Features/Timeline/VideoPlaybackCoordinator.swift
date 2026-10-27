#if os(iOS)
import Foundation
import Observation

/// A single active item prevents neighboring or quoted videos playing together.
@MainActor
@Observable
final class VideoPlaybackCoordinator {
    static let shared = VideoPlaybackCoordinator()
    private(set) var activeID: UUID?
    @ObservationIgnored private var scores: [UUID: Double] = [:]
    @ObservationIgnored private var pausedIDs: Set<UUID> = []
    @ObservationIgnored private var manualID: UUID?

    func update(_ id: UUID, visibleFraction: Double, policy: VideoPlaybackPolicy) {
        if visibleFraction <= 0 {
            scores.removeValue(forKey: id)
            pausedIDs.remove(id)
            if manualID == id { manualID = nil }
        } else if policy == .mutedAutoplay, visibleFraction >= 0.5, !pausedIDs.contains(id) {
            scores[id] = visibleFraction
        } else {
            scores.removeValue(forKey: id)
        }
        select()
    }

    func playManually(_ id: UUID) {
        pausedIDs.remove(id)
        manualID = id
        activeID = id
    }

    func pauseByUser(_ id: UUID) {
        pausedIDs.insert(id)
        scores.removeValue(forKey: id)
        if manualID == id { manualID = nil }
        select()
    }

    func remove(_ id: UUID) {
        pausedIDs.remove(id)
        scores.removeValue(forKey: id)
        if manualID == id { manualID = nil }
        select()
    }

    func isManualSelection(_ id: UUID) -> Bool { manualID == id }

    func suspend() {
        scores.removeAll()
        manualID = nil
        activeID = nil
    }

    private func select() {
        activeID = manualID ?? Self.mostVisible(scores, retaining: activeID)
    }

    static func mostVisible(_ scores: [UUID: Double], retaining current: UUID?) -> UUID? {
        guard let maximum = scores.values.max() else { return nil }
        if let current, scores[current] == maximum { return current }
        return scores.filter { $0.value == maximum }.keys.min { $0.uuidString < $1.uuidString }
    }
}

#endif
