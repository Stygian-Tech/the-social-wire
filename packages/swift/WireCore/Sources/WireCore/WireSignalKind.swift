public enum WireSignalKind: String, Codable, CaseIterable, Sendable {
  case recommendation
  case share
  case quote
  case reply
  case like
  case repost
  case publication
}
