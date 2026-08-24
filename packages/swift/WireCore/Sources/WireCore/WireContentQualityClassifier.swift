import Foundation

public enum WireContentQualityClassifier {
  public static func targetKind(for rawURL: String, standardSite: Bool = false) -> WireTargetKind {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("at://") {
      return trimmed.lowercased().contains("/app.bsky.feed.post/") ? .socialPost : .unsupported
    }
    guard let url = URL(string: trimmed), let host = url.host?.lowercased() else {
      return .unsupported
    }
    let path = url.path.lowercased()
    if (host == "bsky.app" || host.hasSuffix(".bsky.app")) {
      if path.range(of: #"^/profile/[^/]+/post/[^/]+/?$"#, options: .regularExpression) != nil {
        return .socialPost
      }
      return .profileOrFeed
    }
    return standardSite ? .standardSiteDocument : .externalArticle
  }

  public static func assess(
    canonicalURL: String,
    title: String?,
    summary: String?,
    sourceText: String? = nil,
    topicKeys: [String] = [],
    hasProductOfferSchema: Bool = false
  ) -> WireCommercialAssessment {
    let text = ([title, summary, sourceText].compactMap { $0 } + topicKeys)
      .joined(separator: " ").lowercased()
    var reasons: [WireCommercialReason] = []
    var score = 0.0
    func add(_ reason: WireCommercialReason, _ value: Double) {
      guard !reasons.contains(reason) else { return }
      reasons.append(reason)
      score += value
    }

    if containsAny(text, ["paid partnership", "sponsored post", "affiliate link"])
      || containsPattern(text, #"(?<![a-z0-9])#(?:ad|sponsored)(?![a-z0-9])"#)
    {
      add(.explicitAdDisclosure, 4)
    }
    if containsAny(text, ["buy now", "shop now", "order today", "use code", "promo code", "book a demo", "register now", "limited-time offer", "limited time offer", "subscribe and save", "free trial", "tag a friend", "follow and repost"]) {
      add(.purchaseCTA, 2)
    }
    if text.range(of: #"(?:\$|€|£)\s?\d|\d+%\s+off"#, options: .regularExpression) != nil {
      add(.priceOrDiscount, 1)
    }
    if containsAny(text, ["whatsapp", "telegram", "dm to order", "contact us at"]) {
      add(.contactSolicitation, 1)
    }
    if hasProductOfferSchema
      || containsAny(text, [#"\"@type\":\"product\""#, #"\"@type\":\"offer\""#, "pricecurrency", "availability"])
    {
      add(.productOfferSchema, 3)
    }

    if let components = URLComponents(string: canonicalURL) {
      let queryNames = Set((components.queryItems ?? []).map { $0.name.lowercased() })
      if !queryNames.isDisjoint(with: ["affiliate", "aff", "ref", "referrer", "coupon", "promo"]) {
        add(.affiliateParameter, 2)
      }
      if queryNames.contains(where: { $0.hasPrefix("utm_") })
        || !queryNames.isDisjoint(with: ["gclid", "fbclid", "dclid", "msclkid"])
      {
        add(.trackingParameters, 0.25)
      }
      let segments = components.path.removingPercentEncoding?.lowercased()
        .split(separator: "/").map(String.init) ?? []
      if segments.contains(where: { ["ref", "invite", "aff", "affiliate"].contains($0) }) {
        add(.referralPath, 2)
      }
      let slugTokens = Set(segments.flatMap {
        $0.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).map(String.init)
      })
      if !slugTokens.isDisjoint(with: [
        "sponsored", "advertorial", "deals", "offers", "shop", "store", "product", "giveaway",
      ]) || segments.contains(where: { ["partner-content", "brand-studio"].contains($0) }) {
        add(.commercialSlug, 1)
      }
    }
    return WireCommercialAssessment(score: score, reasons: reasons)
  }

  private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
    needles.contains { text.contains($0) }
  }

  private static func containsPattern(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
  }
}
