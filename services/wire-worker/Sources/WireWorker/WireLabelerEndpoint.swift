import Foundation

struct WireLabelerEndpoint: Equatable, Sendable {
  /// Bluesky's first-party moderation service. Operators can replace or extend this list.
  static let blueskyDefault =
    "did:plc:ar7c4by46qjdydhdevvrndac|https://mod.bsky.app"

  let sourceDID: String
  let baseURL: URL

  var endpointHost: String { baseURL.host ?? "unknown" }

  static func parse(_ rawValue: String) throws -> [WireLabelerEndpoint] {
    let entries = rawValue.split(separator: ",", omittingEmptySubsequences: true)
    guard !entries.isEmpty else { throw WireWorkerConfigError.invalidLabeler(rawValue) }
    var result: [WireLabelerEndpoint] = []
    var seenSources: Set<String> = []
    for rawEntry in entries {
      let parts = rawEntry.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { throw WireWorkerConfigError.invalidLabeler(String(rawEntry)) }
      let sourceDID = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let endpoint = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard sourceDID.hasPrefix("did:"), sourceDID.utf8.count <= 256,
        let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
        url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
        seenSources.insert(sourceDID).inserted
      else {
        throw WireWorkerConfigError.invalidLabeler(String(rawEntry))
      }
      result.append(
        WireLabelerEndpoint(
          sourceDID: sourceDID,
          baseURL: url.absoluteURL
        )
      )
    }
    return result
  }
}
