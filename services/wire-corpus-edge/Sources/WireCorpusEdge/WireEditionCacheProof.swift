import Foundation
import SocialWireRedis
import WireCore

/// Raw membership precedes presentation caps and minimum-sized module filtering.
struct WireEditionCacheProof: Codable, Sendable {
  let modulePrefix: String
  let moduleKeys: [String]
  let stories: [[String]]
  let accounts: [String]
  let hasMore: Bool

  func matches(revision: String, region: WireViewerRegion?) -> Bool {
    var modules: [String] = []
    var items: [[String]] = []
    var profiles: [(Int, String)] = []
    var continuation: Bool?
    for token in revision.split(separator: "\n") {
      guard let fields = try? JSONSerialization.jsonObject(with: Data(token.utf8)) as? [Any],
        let kind = fields.first as? String else { return false }
      switch kind {
      case "module":
        guard fields.count >= 2, let key = fields[1] as? String else { return false }
        modules.append(key)
      case "item":
        guard fields.count >= 4, let module = fields[1] as? String,
          let item = fields[3] as? String else { return false }
        items.append([module, item])
      case "account":
        guard fields.count >= 3, let position = fields[1] as? Int,
          let did = fields[2] as? String else { return false }
        profiles.append((position, did))
      case "continuation":
        guard fields.count == 2, let value = fields[1] as? Bool else { return false }
        continuation = value
      case "generation": break
      default: return false
      }
    }
    let outsidePrefix = WireViewerRegion.outsideUnitedStates.rawValue + ":"
    let expectedPrefix = region == .outsideUnitedStates && modules.contains { $0.hasPrefix(outsidePrefix) }
      ? outsidePrefix : ""
    func selected(_ key: String) -> Bool {
      expectedPrefix.isEmpty ? !key.contains(":") : key.hasPrefix(expectedPrefix)
    }
    let expectedAccounts = profiles.sorted { $0.0 < $1.0 }.prefix(10).map(\.1)
    return modulePrefix == expectedPrefix
      && moduleKeys.sorted() == modules.filter(selected).sorted()
      && RedisPayloadMembership.matches(stories, expected: items.filter { selected($0[0]) })
      && accounts.sorted() == expectedAccounts.sorted()
      && continuation == hasMore
  }
}
