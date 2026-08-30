enum CircleGraphSnapshotSource: String, Codable, Equatable, Sendable {
  case refreshed
  case freshCache
  case staleCache
}
