import Foundation

public struct WireDomainPenaltyPolicy: Codable, Equatable, Sendable {
  public var penalties: [String: Double]

  public init(penalties: [String: Double] = Self.defaults) {
    self.penalties = penalties
  }

  public static let defaults: [String: Double] = [
    "bsky.app": 0.05,
    "facebook.com": 0.05,
    "fb.com": 0.05,
    "fb.watch": 0.05,
    "instagram.com": 0.05,
    "linkedin.com": 0.05,
    "pinterest.com": 0.05,
    "redd.it": 0.04,
    "reddit.com": 0.04,
    "threads.net": 0.05,
    "tiktok.com": 0.05,
    "twitch.tv": 0.06,
    "twitter.com": 0.05,
    "x.com": 0.05,
    "youtu.be": 0.06,
    "youtube.com": 0.06,
  ]

  public func validate() throws {
    guard penalties.allSatisfy({ domain, penalty in
      domain == Self.normalize(domain)
        && !domain.isEmpty
        && !domain.hasPrefix(".")
        && penalty.isFinite
        && (0...0.20).contains(penalty)
    }) else {
      throw WireRankingConfigError.invalidThreshold
    }
  }

  public func penalty(for sourceDomain: String) -> Double {
    let host = Self.normalize(sourceDomain)
    return penalties
      .filter { root, _ in host == root || host.hasSuffix(".\(root)") }
      .max { lhs, rhs in lhs.key.count < rhs.key.count }?
      .value ?? 0
  }

  private static func normalize(_ domain: String) -> String {
    domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
