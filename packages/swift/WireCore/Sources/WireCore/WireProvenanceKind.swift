public enum WireProvenanceKind: String, Codable, CaseIterable, Sendable {
  case standardSite = "standard_site"
  case recommendation
  case directShare = "direct_share"
  case quote
  case repost
  case like
  case rss
}
