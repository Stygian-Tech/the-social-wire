import Testing
@testable import WireCore

@Suite("The Wire base content safety classifier")
struct WireBaseContentSafetyClassifierTests {
  @Test("blocks known explicit publishers and their subdomains")
  func explicitPublisher() {
    #expect(WireBaseContentSafetyClassifier.isExplicitAdultContent(
      canonicalURL: "https://www.3movs.com/videos/123/story",
      title: "A new upload",
      summary: nil
    ))
    #expect(!WireBaseContentSafetyClassifier.isExplicitAdultContent(
      canonicalURL: "https://not3movs.com/news/story",
      title: "A new upload",
      summary: nil
    ))
  }

  @Test("blocks unambiguous explicit language")
  func unambiguousLanguage() {
    #expect(WireBaseContentSafetyClassifier.isExplicitAdultContent(
      canonicalURL: "https://example.com/story",
      title: "Video",
      summary: "A hardcore scene featuring deep blowjobs"
    ))
  }

  @Test("requires corroboration for contextual adult terms")
  func corroboratedLanguage() {
    #expect(WireBaseContentSafetyClassifier.isExplicitAdultContent(
      canonicalURL: "https://example.com/story",
      title: "Scene tags",
      summary: "bdsm gagged naked"
    ))
    #expect(!WireBaseContentSafetyClassifier.isExplicitAdultContent(
      canonicalURL: "https://health.example/report",
      title: "Breast cancer research",
      summary: "Adult patients joined a sexual-health study"
    ))
    #expect(!WireBaseContentSafetyClassifier.isExplicitAdultContent(
      canonicalURL: "https://policy.example/report",
      title: "Legislation on pornography",
      summary: "A report about online safety policy"
    ))
  }

  @Test("blocks explicit anatomy and contextual sexual language seen in live projections")
  func liveProjectionLanguage() {
    #expect(WireBaseContentSafetyClassifier.isExplicitAdultContent(
      canonicalURL: "https://example.com/video/one",
      title: "Daddy's Young Bitch Boi",
      summary: "An amateur daddy with a cock shows his experience by dominating a young partner in a hot, steamy video."
    ))
    #expect(WireBaseContentSafetyClassifier.isExplicitAdultContent(
      canonicalURL: "https://example.com/video/two",
      title: "A lactation video",
      summary: "An explicit description containing tits, dick, and pussy."
    ))
    #expect(!WireBaseContentSafetyClassifier.isExplicitAdultContent(
      canonicalURL: "https://farm.example/show",
      title: "Prize-winning cock",
      summary: "An amateur poultry keeper shares a video from the county fair."
    ))
  }

  @Test("uses publisher tags only with an adult-media context")
  func taggedMediaContext() {
    #expect(WireBaseContentSafetyClassifier.isExplicitAdultContent(
      canonicalURL: "https://shima.donmai.us/posts/123",
      title: "Illustration",
      summary: "large_breasts highres"
    ))
    #expect(!WireBaseContentSafetyClassifier.isExplicitAdultContent(
      canonicalURL: "https://art.example/posts/123",
      title: "Illustration",
      summary: "large_breasts highres"
    ))
  }
}
