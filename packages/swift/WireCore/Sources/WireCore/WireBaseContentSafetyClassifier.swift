import Foundation

public enum WireBaseContentSafetyClassifier {
  public static let labelSource = "app.thesocialwire.base-content-labeler"

  public static func isExplicitAdultContent(
    canonicalURL: String,
    title: String?,
    summary: String?,
    sourceText: String? = nil,
    topicKeys: [String] = []
  ) -> Bool {
    let host = URL(string: canonicalURL)?.host?.lowercased() ?? ""
    if matches(host: host, domains: ["3movs.com", "3dporndude.com", "mengem.com"]) {
      return true
    }

    let text = ([title, summary, sourceText].compactMap { $0 } + topicKeys)
      .joined(separator: " ").lowercased()
    let tokens = Set(
      text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    )

    let unambiguousTokens: Set<String> = [
      "blowjob", "blowjobs", "cumshot", "cumshots", "deepthroat", "gangbang",
      "gangbangs", "hardcoreporn", "hentai", "pornographic",
    ]
    if !tokens.isDisjoint(with: unambiguousTokens) { return true }

    let corroboratingTokens: Set<String> = [
      "bdsm", "cock", "cocks", "fuck", "fucking", "gagged", "hardcore", "milf",
      "naked", "pussy", "pussies", "stepsis", "stepbrother",
    ]
    if tokens.intersection(corroboratingTokens).count >= 2 { return true }

    let explicitAnatomyTokens: Set<String> = [
      "cock", "cocks", "dick", "dicks", "pussy", "pussies", "tit", "tits",
    ]
    if tokens.intersection(explicitAnatomyTokens).count >= 2 { return true }

    let adultContextTokens: Set<String> = [
      "daddy", "dominating", "fetish", "hardcore", "horny", "porno", "porn", "steamy",
    ]
    if !tokens.isDisjoint(with: explicitAnatomyTokens),
      tokens.intersection(adultContextTokens).count >= 2
    {
      return true
    }

    let adultTagTokens: Set<String> = corroboratingTokens.union([
      "breast", "breasts", "boob", "boobs", "groin", "nude",
    ])
    return matches(host: host, domains: ["donmai.us"])
      && !tokens.isDisjoint(with: adultTagTokens)
  }

  private static func matches(host: String, domains: [String]) -> Bool {
    domains.contains { host == $0 || host.hasSuffix(".\($0)") }
  }
}
