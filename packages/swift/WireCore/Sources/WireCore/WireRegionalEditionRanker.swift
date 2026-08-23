import Foundation

/// Produces a bounded presentation variant from the same admitted first-page
/// corpus. Topic keys remain internal and never enter a public Wire DTO.
public enum WireRegionalEditionRanker {
  public static let americanPoliticsDownrankSlots = 3

  public static func downrankAmericanPolitics<Item>(
    in items: [Item],
    topicKeys: (Item) -> [String],
    reasons: (Item) -> [WireReasonCode]
  ) -> [Item] {
    items.enumerated().sorted { lhs, rhs in
      let lhsFlagged = shouldDownrank(topicKeys: topicKeys(lhs.element), reasons: reasons(lhs.element))
      let rhsFlagged = shouldDownrank(topicKeys: topicKeys(rhs.element), reasons: reasons(rhs.element))
      let lhsPosition = lhs.offset + (lhsFlagged ? americanPoliticsDownrankSlots : 0)
      let rhsPosition = rhs.offset + (rhsFlagged ? americanPoliticsDownrankSlots : 0)
      if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
      if lhsFlagged != rhsFlagged { return !lhsFlagged }
      return lhs.offset < rhs.offset
    }.map(\.element)
  }

  public static func shouldDownrank(
    topicKeys: [String],
    reasons: [WireReasonCode]
  ) -> Bool {
    let globallyImportant: Set<WireReasonCode> = [
      .breakingStory, .widelyDiscussed, .sharedAcrossCommunities,
    ]
    guard globallyImportant.isDisjoint(with: reasons) else { return false }

    let topics = Set(topicKeys.map(normalizedTopic).filter { !$0.isEmpty })
    let explicit = [
      "american-politics", "politics-us", "politics-usa", "united-states-politics",
      "us-politics", "usa-politics",
    ]
    if explicit.contains(where: topics.contains) { return true }

    let usTopics: Set<String> = ["america", "american", "united-states", "us", "usa"]
    let politicsTopics: Set<String> = [
      "election", "elections", "government", "political", "politics",
    ]
    return !topics.isDisjoint(with: usTopics) && !topics.isDisjoint(with: politicsTopics)
  }

  private static func normalizedTopic(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .replacingOccurrences(of: "_", with: "-")
      .split(whereSeparator: { $0 == " " || $0 == "-" })
      .map(String.init)
      .joined(separator: "-")
  }
}
