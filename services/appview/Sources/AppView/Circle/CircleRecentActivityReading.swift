import Foundation

protocol CircleRecentActivityReading: Sendable {
  /// Returns the most recent known signal time. Missing keys mean no known recent activity.
  func mostRecentActivity(for actorDIDs: Set<String>) async throws -> [String: Date]
}
