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
      "+ 0.14 * shareVelocity1h",
      "+ 0.04 * likeBreadthVelocity",
      "+ 0.04 * repostBreadthVelocity",
      "+ 0.18 * communitySpread",
      "+ 0.10 * freshness",
      "+ 0.06 * resurfacingAcceleration",
      "+ 0.08 * sourceConfidence",
      "+ 0.09 * standardSiteAuthority",
      "+ 0.05 * openGraphMetadata",
      "+ 0.08 * recommendationBreadth",
      "+ 0.06 * positiveFeedbackBreadth",
      "0.10 * negativeFeedbackBreadth",
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
