import Foundation

struct CircleGraphSnapshotFreshness: Equatable, Sendable {
  let source: CircleGraphSnapshotSource
  let age: TimeInterval
  let freshTarget: TimeInterval
  let staleMaximum: TimeInterval

  var isStale: Bool { source == .staleCache }
  var refreshFailed: Bool { source == .staleCache }
}
