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
      "0.24 * distinctSharers24h",
      "+ 0.20 * shareVelocity1h",
      "+ 0.08 * likeBreadthVelocity",
      "+ 0.08 * repostBreadthVelocity",
      "+ 0.15 * communitySpread",
      "+ 0.12 * freshness",
      "+ 0.08 * resurfacingAcceleration",
      "+ 0.05 * sourceConfidence",
      "source confidence is finite and at least `0.25`",
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
