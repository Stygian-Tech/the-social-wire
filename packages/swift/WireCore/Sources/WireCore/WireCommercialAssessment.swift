public enum WireCommercialClass: String, Codable, Equatable, Sendable {
  case normal
  case limited
  case probableAd = "probable_ad"
}

public enum WireCommercialReason: String, Codable, CaseIterable, Sendable {
  case explicitAdDisclosure = "explicit_ad_disclosure"
  case purchaseCTA = "purchase_cta"
  case priceOrDiscount = "price_or_discount"
  case affiliateParameter = "affiliate_parameter"
  case referralPath = "referral_path"
  case commercialSlug = "commercial_slug"
  case productOfferSchema = "product_offer_schema"
  case trackingParameters = "tracking_parameters"
  case contactSolicitation = "contact_solicitation"
}

public struct WireCommercialAssessment: Codable, Equatable, Sendable {
  public let score: Double
  public let classification: WireCommercialClass
  public let reasons: [WireCommercialReason]

  public init(score: Double, reasons: [WireCommercialReason]) {
    self.score = max(0, score)
    self.classification = score > 5 ? .probableAd : (score >= 3 ? .limited : .normal)
    self.reasons = Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
  }
}
