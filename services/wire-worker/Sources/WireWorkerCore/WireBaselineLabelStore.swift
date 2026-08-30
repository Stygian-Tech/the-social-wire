import Foundation

protocol WireBaselineLabelStore: Sendable {
  func loadTargets(limit: Int, asOf: Date) async throws -> [WireBaselineLabelTarget]
  func replaceSnapshot(
    labels: [WireBaselineLabel],
    labelers: [WireLabelerEndpoint],
    refreshedCanonicalKeys: [String],
    targetCount: Int,
    refreshedAt: Date
  ) async throws
  func verifyFresh(
    labelers: [WireLabelerEndpoint],
    asOf: Date,
    maximumAge: TimeInterval
  ) async throws
}
