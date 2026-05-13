import AsyncHTTPClient
import Foundation
import Logging

/// A single step in the publication discovery chain.
protocol DiscoveryStep: Sendable {
  var name: String { get }
  func discover(authorDID: String, plcURL: String, httpClient: HTTPClient) async throws -> DiscoveredPublication?
}

// MARK: - Step 1: Lexicon-native discovery

/// Looks for a `standard.site/publication` (or equivalent) record in the author's
/// ATProto PDS repo. This is the canonical, structured way for an author to declare
/// a publication.
struct LexiconNativeDiscovery: DiscoveryStep {
  let name = "lexicon-native"

  // Known lexicon collection IDs for standard.site publications.
  // Update this list as the standard.site ecosystem defines its lexicons.
  static let knownPublicationCollections = [
    "site.standard.publication",
    "com.standard.publication",
    "app.bsky.publication",  // hypothetical — check actual lexicon IDs when available
  ]

  func discover(authorDID: String, plcURL: String, httpClient: HTTPClient) async throws -> DiscoveredPublication? {
    guard
      let pdsEndpoint = try await ATProtoPdsResolution.resolvePdsBase(
        repoDid: authorDID,
        plcBase: plcURL,
        httpClient: httpClient,
        timeout: .seconds(10)
      )
    else {
      return nil
    }

    for collection in Self.knownPublicationCollections {
      if let pub = try await fetchPublicationRecord(
        from: pdsEndpoint,
        did: authorDID,
        collection: collection,
        httpClient: httpClient
      ) {
        return pub
      }
    }

    return nil
  }

  private func fetchPublicationRecord(
    from pdsEndpoint: String,
    did: String,
    collection: String,
    httpClient: HTTPClient
  ) async throws -> DiscoveredPublication? {
    let base = pdsEndpoint.hasSuffix("/") ? String(pdsEndpoint.dropLast()) : pdsEndpoint
    let url = "\(base)/xrpc/com.atproto.repo.listRecords?repo=\(did)&collection=\(collection)&limit=1"

    var request = HTTPClientRequest(url: url)
    request.headers.add(name: "Accept", value: "application/json")

    let response = try await httpClient.execute(request, timeout: .seconds(10))
    guard response.status == .ok else { return nil }

    let body = try await response.body.collect(upTo: 64 * 1024)
    guard
      let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
      let records = json["records"] as? [[String: Any]],
      let first = records.first,
      let uri = first["uri"] as? String,
      let value = first["value"] as? [String: Any],
      let title = value["title"] as? String ?? (value["name"] as? String)
    else { return nil }

    return DiscoveredPublication(
      publicationId: uri,
      authorDid: did,
      authorHandle: nil,
      title: title,
      avatarUrl: value["avatarUrl"] as? String,
      discoveredAt: Date()
    )
  }
}

// MARK: - Step 2: Profile link heuristic

/// Scans the author's `app.bsky.actor.profile` record for standard.site URLs
/// in their description or website field.
struct ProfileLinkHeuristic: DiscoveryStep {
  let name = "profile-link-heuristic"

  static let standardSiteHostnames: Set<String> = [
    "standard.site",
    "www.standard.site",
  ]

  func discover(authorDID: String, plcURL: String, httpClient: HTTPClient) async throws -> DiscoveredPublication? {
    _ = plcURL
    let encoded = authorDID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? authorDID
    let url =
      "\(ATProtoPdsResolution.bskyAppViewPublic)/xrpc/app.bsky.actor.getProfile?actor=\(encoded)"

    var request = HTTPClientRequest(url: url)
    request.headers.add(name: "Accept", value: "application/json")

    let response = try await httpClient.execute(request, timeout: .seconds(10))
    guard response.status == .ok else { return nil }

    let body = try await response.body.collect(upTo: 64 * 1024)
    guard let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any] else {
      return nil
    }

    let handle = json["handle"] as? String
    let displayName = json["displayName"] as? String ?? handle ?? authorDID
    let avatar = json["avatar"] as? String

    // Check description and website for standard.site links
    let candidates: [String?] = [
      json["description"] as? String,
      (json["associated"] as? [String: Any])?["website"] as? String,
    ]

    for candidate in candidates.compactMap({ $0 }) {
      if let url = extractStandardSiteURL(from: candidate) {
        return DiscoveredPublication(
          publicationId: url,
          authorDid: authorDID,
          authorHandle: handle,
          title: displayName,
          avatarUrl: avatar,
          discoveredAt: Date()
        )
      }
    }

    return nil
  }

  private func extractStandardSiteURL(from text: String) -> String? {
    // Match https://standard.site/<path> or http://standard.site/<path>
    let pattern = #"https?://(?:www\.)?standard\.site[^\s\"'<>]*"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
      return nil
    }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return nil }
    guard let swiftRange = Range(match.range, in: text) else { return nil }
    return String(text[swiftRange])
  }
}

// MARK: - Step 3: Directory / AppView fallback

/// Queries a standard.site index / directory API if one is available.
/// This is a placeholder for when the standard.site ecosystem provides
/// a discovery API.
struct DirectoryFallback: DiscoveryStep {
  let name = "directory-fallback"

  // Update this URL when a standard.site directory API becomes available.
  static let directoryURL: String? = nil

  func discover(authorDID: String, plcURL: String, httpClient: HTTPClient) async throws -> DiscoveredPublication? {
    _ = plcURL
    guard let directoryURL = Self.directoryURL else {
      // Directory not yet available — skip this step.
      return nil
    }

    let encoded = authorDID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? authorDID
    let url = "\(directoryURL)/lookup?did=\(encoded)"

    var request = HTTPClientRequest(url: url)
    request.headers.add(name: "Accept", value: "application/json")

    let response = try await httpClient.execute(request, timeout: .seconds(10))
    guard response.status == .ok else { return nil }

    let body = try await response.body.collect(upTo: 32 * 1024)
    guard
      let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
      let publicationId = json["publicationId"] as? String,
      let title = json["title"] as? String
    else { return nil }

    return DiscoveredPublication(
      publicationId: publicationId,
      authorDid: authorDID,
      authorHandle: json["handle"] as? String,
      title: title,
      avatarUrl: json["avatarUrl"] as? String,
      discoveredAt: Date()
    )
  }
}
