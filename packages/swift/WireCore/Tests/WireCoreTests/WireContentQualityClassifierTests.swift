import Testing
@testable import WireCore

@Suite("The Wire content quality classifier")
struct WireContentQualityClassifierTests {
  @Test("classifies Bluesky post records and permalinks as signal envelopes")
  func socialPostTargets() {
    #expect(WireContentQualityClassifier.targetKind(
      for: "at://did:plc:alice/app.bsky.feed.post/3abc") == .socialPost)
    #expect(WireContentQualityClassifier.targetKind(
      for: "https://bsky.app/profile/alice.example/post/3abc") == .socialPost)
    #expect(WireContentQualityClassifier.targetKind(
      for: "https://bsky.app/profile/alice.example") == .profileOrFeed)
    #expect(!WireContentQualityClassifier.targetKind(
      for: "https://bsky.app/profile/alice.example/post/3abc").canCreateItem)
  }

  @Test("rejects dedicated operational status hosts without path-only false positives")
  func operationalStatusTargets() {
    #expect(WireContentQualityClassifier.targetKind(
      for: "https://status.strongvpn.com/incidents/mrwzl3d5fz3w",
      standardSite: true
    ) == .operationalStatus)
    #expect(WireContentQualityClassifier.targetKind(
      for: "https://example.statuspage.io/incident/1") == .operationalStatus)
    #expect(WireContentQualityClassifier.targetKind(
      for: "https://fedilist.com/instance/example.com",
      standardSite: true
    ) == .operationalStatus)
    #expect(WireContentQualityClassifier.targetKind(
      for: "https://notfedilist.com/instance/example.com") == .externalArticle)
    #expect(WireContentQualityClassifier.targetKind(
      for: "https://fedilist.com.evil.example/instance/example.com") == .externalArticle)
    #expect(WireContentQualityClassifier.targetKind(
      for: "https://news.example/status/report") == .externalArticle)
    #expect(!WireTargetKind.operationalStatus.canCreateItem)
  }

  @Test("combines disclosure, CTA, price, slug, and affiliate evidence")
  func probableAdvertisement() {
    let result = WireContentQualityClassifier.assess(
      canonicalURL: "https://shop.example/deals/product?affiliate=sam",
      title: "#ad — Save 30%",
      summary: "Buy now and use code WIRE"
    )
    #expect(result.classification == .probableAd)
    #expect(result.reasons.contains(.explicitAdDisclosure))
    #expect(result.reasons.contains(.purchaseCTA))
    #expect(result.reasons.contains(.affiliateParameter))
    #expect(result.reasons.contains(.commercialSlug))
  }

  @Test("tracking attribution alone remains normal")
  func trackingOnly() {
    let result = WireContentQualityClassifier.assess(
      canonicalURL: "https://news.example/report?utm_campaign=morning",
      title: "Independent reporting",
      summary: "A detailed investigation"
    )
    #expect(result.classification == .normal)
    #expect(result.score == 0.25)
  }

  @Test("Product or Offer schema is strong commercial evidence")
  func productOfferSchema() {
    let result = WireContentQualityClassifier.assess(
      canonicalURL: "https://merchant.example/widget",
      title: "Widget",
      summary: "Product details",
      hasProductOfferSchema: true
    )
    #expect(result.classification == .limited)
    #expect(result.reasons == [.productOfferSchema])
  }

  @Test("affiliate disclosure is strong evidence and shopping is weak corroboration")
  func affiliateDisclosure() {
    let result = WireContentQualityClassifier.assess(
      canonicalURL: "https://publisher.example/shopping/roundup",
      title: "A useful roundup",
      summary: nil,
      hasAffiliateDisclosure: true
    )
    #expect(result.score == 5)
    #expect(result.classification == .limited)
    #expect(Set(result.reasons) == [.explicitAdDisclosure, .commercialSlug])
  }

  @Test("does not treat hashtag prefixes as ad disclosures")
  func disclosureBoundaries() {
    let result = WireContentQualityClassifier.assess(
      canonicalURL: "https://travel.example/story",
      title: "#adventure in the mountains",
      summary: nil
    )
    #expect(!result.reasons.contains(.explicitAdDisclosure))
  }

  @Test("recognizes commercial tokens inside a readable slug")
  func readableCommercialSlug() {
    let result = WireContentQualityClassifier.assess(
      canonicalURL: "https://publisher.example/partner/sponsored-story",
      title: "A story",
      summary: nil
    )
    #expect(result.reasons.contains(.commercialSlug))
  }
}
