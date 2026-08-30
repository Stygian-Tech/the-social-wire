public enum WireTargetKind: String, Codable, Equatable, Sendable {
  case externalArticle = "external_article"
  case standardSiteDocument = "standard_site_document"
  case socialPost = "social_post"
  case profileOrFeed = "profile_or_feed"
  case commerceOrAd = "commerce_or_ad"
  case operationalStatus = "operational_status"
  case unsupported

  public var canCreateItem: Bool {
    self == .externalArticle || self == .standardSiteDocument
  }
}
