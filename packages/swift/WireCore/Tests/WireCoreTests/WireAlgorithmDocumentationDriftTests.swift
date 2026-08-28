import Foundation
import Testing
@testable import WireCore

@Suite("The Wire algorithm documentation")
struct WireAlgorithmDocumentationDriftTests {
  @Test("documents implemented versions, weights, thresholds, caps, and product copy")
  func sourceOfTruthTokens() throws {
    let readme = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("README.md")
    let text = try String(contentsOf: readme, encoding: .utf8)
    for token in [
      WireCanonicalizer.version,
      WireRankingConfig().version,
      WireEditionAssembler.version,
      "0.22 * distinctSharers24h",
      "+ 0.10 * shareVelocity1h",
      "+ 0.02 * likeBreadthVelocity",
      "+ 0.02 * repostBreadthVelocity",
      "+ 0.14 * communitySpread",
      "+ 0.18 * freshness",
      "+ 0.06 * resurfacingAcceleration",
      "+ 0.08 * sourceConfidence",
      "+ 0.11 * standardSiteAuthority",
      "+ 0.05 * openGraphMetadata",
      "+ 0.10 * recommendationBreadth",
      "+ 0.06 * positiveFeedbackBreadth",
      "0.10 * negativeFeedbackBreadth",
      "`0.05` when the story has no usable presentation thumbnail",
      "never substitute the multilingual `und` generation",
      "floor(asOf / 1,800 seconds)",
      "nudge in `[0, 0.005]`",
      "youtube.com",
      "facebook.com",
      "instagram.com",
      "reddit.com",
      "Social Wire article feedback cannot admit",
      "source confidence is finite and at least `0.25`",
      "five distinct high-intent actors",
      "quality reserve",
      "four items per source domain",
      "three per publication",
      "two per author",
      "five per topic",
      "ten per dominant active-actor community",
      "up to four lead stories",
      "one feature and three supporting stories",
      "stable three-position penalty",
      "Stories marked Breaking, Widely Discussed, or Across Communities are exempt",
      "up to six publication panels",
      "fewer than four stories",
      "caps at ten",
      "Breaking & Developing",
      "Across Communities",
      "`fresh_publication` remains a presentation reason",
      "three distinct HMAC-counted public speakers",
      "The Wire",
      "Important stories across the social web",
      String(WireDataPolicy.maximumFollowEdgesPerActor),
      String(WireDataPolicy.minimumLocaleCandidates),
    ] {
      #expect(text.contains(token), "README is missing algorithm token: \(token)")
    }
  }
}
