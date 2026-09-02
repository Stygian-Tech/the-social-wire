struct MarkReadBeforeRequest: Codable, Sendable {
  let scope: ScopedMarkAllReadScope
  let before: String
}
