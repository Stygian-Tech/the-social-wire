import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging

/// Fetches and returns entry feeds and entry detail from the ATProto network.
/// Sanitizes content HTML before returning it to clients.
///
/// Repo reads (`com.atproto.repo.*` for `site.standard.*`) target each author's PDS
/// (PLC-resolved), not the public App View — same as the web app's `atprotoClient`.
actor ContentService {
  private let httpClient: HTTPClient
  private let cache: any CacheStore
  private let logger: Logger
  private let plcURL: String

  init(httpClient: HTTPClient, cache: any CacheStore, logger: Logger, plcURL: String) {
    self.httpClient = httpClient
    self.cache = cache
    self.logger = logger
    self.plcURL = plcURL
  }

  // MARK: - Entry list

  /// Returns a paginated list of entries for a publication.
  func entries(for publicationID: String, cursor: String?, limit: Int) async throws -> EntryListResponse {
    let entries = try await fetchEntryList(publicationID: publicationID, cursor: cursor, limit: limit)
    return entries
  }

  // MARK: - Entry detail

  /// Returns full sanitized content for a single entry.
  func entry(id entryID: String) async throws -> EntryDetail {
    // Check cache first
    if let cached = try await cache.cachedEntry(for: entryID) {
      return cached
    }

    // Fetch from ATProto network
    let detail = try await fetchEntryDetail(entryID: entryID)

    // Store in cache
    try await cache.storeEntry(detail)

    return detail
  }

  // MARK: - Private fetch helpers

  private func fetchEntryList(
    publicationID: String,
    cursor: String?,
    limit: Int
  ) async throws -> EntryListResponse {
    // Determine the endpoint based on the publication ID format.
    // For at-uri: fetch from the author's PDS repo.
    // For https: fetch from the standard.site AppView if available.
    let entries: [EntryListItem]
    let nextCursor: String?

    if publicationID.hasPrefix("at://") {
      (entries, nextCursor) = try await fetchFromATProto(
        atURI: publicationID,
        cursor: cursor,
        limit: limit
      )
    } else if publicationID.hasPrefix("https://") || publicationID.hasPrefix("http://") {
      (entries, nextCursor) = try await fetchFromStandardSite(
        url: publicationID,
        cursor: cursor,
        limit: limit
      )
    } else {
      throw HTTPError(.badRequest, message: "Unsupported publication ID format: \(publicationID)")
    }

    return EntryListResponse(entries: entries, cursor: nextCursor)
  }

  private func fetchFromATProto(
    atURI: String,
    cursor: String?,
    limit: Int
  ) async throws -> ([EntryListItem], String?) {
    // Parse at-uri: at://<did>/<collection>/<rkey>
    let parts = atURI.dropFirst("at://".count).split(separator: "/", maxSplits: 2)
    guard parts.count >= 2 else {
      throw HTTPError(.badRequest, message: "Invalid at-uri: \(atURI)")
    }
    let repoAuthority = String(parts[0])
    guard
      let repoDid = try await ATProtoPdsResolution.resolveRepoDid(
        handleOrDid: repoAuthority,
        httpClient: httpClient
      )
    else {
      throw HTTPError(.badRequest, message: "Could not resolve repo: \(repoAuthority)")
    }

    guard
      let pdsBase = try await ATProtoPdsResolution.resolvePdsBase(
        repoDid: repoDid,
        plcBase: plcURL,
        httpClient: httpClient
      )
    else {
      throw HTTPError(.badGateway, message: "Could not resolve PDS for \(repoDid)")
    }

    let wantReverse = true
    let serverReverse =
      wantReverse
      && !ATProtoPdsResolution.relayHostOmitsListRecordsReverse(pdsBase: pdsBase)
    let sortPageNewestFirst = wantReverse && serverReverse != wantReverse

    var urlComponents = URLComponents(string: "\(pdsBase)/xrpc/com.atproto.repo.listRecords")!
    var queryItems = [
      URLQueryItem(name: "repo", value: repoDid),
      URLQueryItem(name: "collection", value: "site.standard.entry"),
      URLQueryItem(name: "limit", value: "\(min(limit, 100))"),
      URLQueryItem(name: "reverse", value: serverReverse ? "true" : "false"),
    ]
    if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
    urlComponents.queryItems = queryItems

    var request = HTTPClientRequest(url: urlComponents.url!.absoluteString)
    request.headers.add(name: "Accept", value: "application/json")

    let response = try await httpClient.execute(request, timeout: .seconds(15))
    guard response.status == .ok else {
      throw HTTPError(.badGateway, message: "ATProto repo returned \(response.status)")
    }

    let body = try await response.body.collect(upTo: 512 * 1024)
    guard let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any] else {
      throw HTTPError(.badGateway, message: "Invalid JSON from ATProto repo")
    }

    var records = (json["records"] as? [[String: Any]]) ?? []
    if sortPageNewestFirst {
      records = Self.sortStandardEntryRecordsNewestFirst(records)
    }
    let entries = records.compactMap { record -> EntryListItem? in
      guard
        let uri = record["uri"] as? String,
        let value = record["value"] as? [String: Any],
        let title = value["title"] as? String
      else { return nil }

      let publishedAtStr = value["createdAt"] as? String ?? value["publishedAt"] as? String ?? ""
      let publishedAt = ISO8601DateFormatter().date(from: publishedAtStr) ?? Date()

      return EntryListItem(
        entryId: uri,
        title: title,
        summary: value["summary"] as? String,
        publishedAt: publishedAt
      )
    }

    return (entries, json["cursor"] as? String)
  }

  private func fetchFromStandardSite(
    url: String,
    cursor: String?,
    limit: Int
  ) async throws -> ([EntryListItem], String?) {
    // Fetch the standard.site RSS/JSON feed for the publication.
    // Phase 1: try appending /feed.json (JSON Feed format).
    let feedURL = url.hasSuffix("/") ? "\(url)feed.json" : "\(url)/feed.json"

    var request = HTTPClientRequest(url: feedURL)
    request.headers.add(name: "Accept", value: "application/json, application/feed+json")

    let response = try await httpClient.execute(request, timeout: .seconds(15))
    guard response.status == .ok else {
      throw HTTPError(.notFound, message: "No feed found at \(feedURL)")
    }

    let body = try await response.body.collect(upTo: 1024 * 1024)
    guard let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any] else {
      throw HTTPError(.badGateway, message: "Invalid JSON feed from \(feedURL)")
    }

    let items = (json["items"] as? [[String: Any]]) ?? []
    let formatter = ISO8601DateFormatter()

    // Apply cursor-based pagination (cursor = last item ID)
    var relevant = items
    if let cursor {
      if let idx = items.firstIndex(where: { ($0["id"] as? String) == cursor }) {
        relevant = Array(items.dropFirst(idx + 1))
      }
    }
    let page = Array(relevant.prefix(limit))
    let nextCursor = page.count == limit ? page.last.flatMap { $0["id"] as? String } : nil

    let entries = page.compactMap { item -> EntryListItem? in
      guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
      let publishedAt = (item["date_published"] as? String).flatMap { formatter.date(from: $0) } ?? Date()
      return EntryListItem(
        entryId: id,
        title: title,
        summary: item["summary"] as? String,
        publishedAt: publishedAt
      )
    }

    return (entries, nextCursor)
  }

  private func fetchEntryDetail(entryID: String) async throws -> EntryDetail {
    // Determine fetch strategy from entryID format
    if entryID.hasPrefix("at://") {
      return try await fetchATProtoEntry(atURI: entryID)
    } else if entryID.hasPrefix("https://") || entryID.hasPrefix("http://") {
      return try await fetchHTTPEntry(url: entryID)
    } else {
      throw HTTPError(.badRequest, message: "Unsupported entry ID format: \(entryID)")
    }
  }

  private func fetchATProtoEntry(atURI: String) async throws -> EntryDetail {
    let parts = atURI.dropFirst("at://".count).split(separator: "/", maxSplits: 2)
    guard parts.count == 3 else {
      throw HTTPError(.badRequest, message: "Invalid at-uri: \(atURI)")
    }
    let did = String(parts[0])
    let collection = String(parts[1])
    let rkey = String(parts[2])

    guard
      let repoDid = try await ATProtoPdsResolution.resolveRepoDid(
        handleOrDid: did,
        httpClient: httpClient
      )
    else {
      throw HTTPError(.badRequest, message: "Could not resolve repo: \(did)")
    }

    guard
      let pdsBase = try await ATProtoPdsResolution.resolvePdsBase(
        repoDid: repoDid,
        plcBase: plcURL,
        httpClient: httpClient
      )
    else {
      throw HTTPError(.badGateway, message: "Could not resolve PDS for \(repoDid)")
    }

    var urlComponents = URLComponents(string: "\(pdsBase)/xrpc/com.atproto.repo.getRecord")!
    urlComponents.queryItems = [
      URLQueryItem(name: "repo", value: repoDid),
      URLQueryItem(name: "collection", value: collection),
      URLQueryItem(name: "rkey", value: rkey),
    ]

    var request = HTTPClientRequest(url: urlComponents.url!.absoluteString)
    request.headers.add(name: "Accept", value: "application/json")

    let response = try await httpClient.execute(request, timeout: .seconds(15))
    guard response.status == .ok else {
      throw HTTPError(.notFound, message: "Entry not found: \(atURI)")
    }

    let body = try await response.body.collect(upTo: 2 * 1024 * 1024)
    guard
      let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
      let value = json["value"] as? [String: Any],
      let title = value["title"] as? String
    else {
      throw HTTPError(.badGateway, message: "Unexpected record shape for \(atURI)")
    }

    let rawContent = value["content"] as? String
      ?? value["body"] as? String
      ?? value["text"] as? String
      ?? ""

    let publishedAtStr = value["createdAt"] as? String ?? value["publishedAt"] as? String ?? ""
    let publishedAt = ISO8601DateFormatter().date(from: publishedAtStr) ?? Date()

    return EntryDetail(
      entryId: atURI,
      title: title,
      publishedAt: publishedAt,
      contentHtml: HTMLSanitizer.sanitize(rawContent),
      originalUrl: value["url"] as? String
    )
  }

  private func fetchHTTPEntry(url: String) async throws -> EntryDetail {
    var request = HTTPClientRequest(url: url)
    request.headers.add(name: "Accept", value: "text/html, application/json")

    let response = try await httpClient.execute(request, timeout: .seconds(15))
    guard response.status == .ok else {
      throw HTTPError(.notFound, message: "Entry not found: \(url)")
    }

    let body = try await response.body.collect(upTo: 2 * 1024 * 1024)
    let rawHTML = String(buffer: body)

    // Basic extraction — Phase 1b can use a proper HTML parser
    let title = extractTitle(from: rawHTML) ?? url

    return EntryDetail(
      entryId: url,
      title: title,
      publishedAt: Date(),
      contentHtml: HTMLSanitizer.sanitize(rawHTML),
      originalUrl: url
    )
  }

  private func extractTitle(from html: String) -> String? {
    guard let titleStart = html.range(of: "<title>", options: .caseInsensitive),
          let titleEnd = html.range(of: "</title>", options: .caseInsensitive)
    else { return nil }
    return String(html[titleStart.upperBound..<titleEnd.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Newest-first ordering for a `listRecords` page when `reverse` must be omitted (Bridgy relay).
  private static func sortStandardEntryRecordsNewestFirst(_ records: [[String: Any]]) -> [[String: Any]] {
    records.sorted { a, b in
      let va = (a["value"] as? [String: Any]) ?? [:]
      let vb = (b["value"] as? [String: Any]) ?? [:]
      let ta = publishedAtString(from: va)
      let tb = publishedAtString(from: vb)
      if ta != tb { return ta > tb }
      let ua = a["uri"] as? String ?? ""
      let ub = b["uri"] as? String ?? ""
      return ua < ub
    }
  }

  private static func publishedAtString(from value: [String: Any]) -> String {
    (value["publishedAt"] as? String)
      ?? (value["createdAt"] as? String)
      ?? (value["indexedAt"] as? String)
      ?? ""
  }
}
