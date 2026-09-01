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
