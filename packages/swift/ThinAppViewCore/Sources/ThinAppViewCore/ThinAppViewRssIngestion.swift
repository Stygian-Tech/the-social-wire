import AsyncHTTPClient
import Foundation
import Logging
import NIOCore

/// Fetches RSS/Atom feeds and upserts Skyreader entries into `content_items`.
public struct ThinAppViewRssIngestion: Sendable {
  private let store: any ThinAppViewStore
  private let httpClient: HTTPClient
  private let config: ThinAppViewConfig
  private let logger: Logger

  public init(
    store: any ThinAppViewStore,
    httpClient: HTTPClient,
    config: ThinAppViewConfig,
    logger: Logger
  ) {
    self.store = store
    self.httpClient = httpClient
    self.config = config
    self.logger = logger
  }

  public func ingestFeed(normalizedFeedUrl: String) async throws -> Int {
    guard RssFeedIdentity.isFetchableFeedUrl(normalizedFeedUrl) else { return 0 }

    var request = HTTPClientRequest(url: normalizedFeedUrl)
    request.headers.add(name: "Accept", value: "application/rss+xml, application/atom+xml, application/xml, text/xml, */*")
    request.headers.add(name: "User-Agent", value: "the-social-wire/thin-appview")

    let response = try await httpClient.execute(request, timeout: .seconds(20))
    guard [200, 403, 406, 415].contains(response.status.code) else { return 0 }

    let body = try await response.body.collect(upTo: 2 * 1024 * 1024)
    let feed = RssFeedParser(data: Data(buffer: body)).parse()
    let capped = Array(feed.items.prefix(config.maxRssItemsPerFeed))
    let now = Date()
    var indexed = 0

    for item in capped {
      let stableKey = RssFeedIdentity.stableItemKey(from: item)
      let uri = RssFeedIdentity.rssEntryId(normalizedFeedUrl: normalizedFeedUrl, stableItemKey: stableKey)
      let createdAt = RenderFieldExtractor.createdAtDate(
        from: [:],
        fallback: ContentRenderFields(title: item.title, publishedAt: item.publishedAtISO)
      )
      let listSummary = listSummary(from: item)
      let htmlBody = htmlBody(from: item)
      let render = ContentRenderFields(
        title: displayTitle(from: item),
        publishedAt: item.publishedAtISO,
        summary: listSummary,
        thumbnailUrl: item.thumbnailUrl,
        contentHtml: htmlBody
      )
      let indexedItem = IndexedContentItem(
        uri: uri,
        cid: RssFeedIdentity.deterministicCid(for: uri),
        authorDid: RssFeedLexicons.rssAuthorDid,
        collection: RssFeedLexicons.skyreaderFeedEntry,
        createdAt: createdAt,
        indexedAt: now,
        publicationSite: normalizedFeedUrl,
        render: render,
        expiresAt: now.addingTimeInterval(config.contentRetentionSeconds)
      )
      try await store.upsertContentItem(indexedItem)
      indexed += 1
    }

    if indexed > 0 {
      logger.info(
        "Indexed RSS feed",
        metadata: [
          "feedUrl": .string(normalizedFeedUrl),
          "items": .stringConvertible(indexed),
        ]
      )
    }
    return indexed
  }

  public func ingestFeeds(_ feedUrls: [String]) async throws -> Int {
    var total = 0
    for raw in feedUrls {
      guard let normalized = RssFeedIdentity.normalizeFeedUrl(raw) else { continue }
      total += try await ingestFeed(normalizedFeedUrl: normalized)
    }
    return total
  }

  public static func feedUrl(fromSubscriptionRecord record: [String: Any]) -> String? {
    guard let raw = (record["feedUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty
    else { return nil }
    if let src = (record["sourceType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
       !src.isEmpty, src != "rss"
    {
      return nil
    }
    return RssFeedIdentity.normalizeFeedUrl(raw)
  }

  private func displayTitle(from item: ParsedRssItem) -> String {
    let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty, title != "Untitled" { return title }
    if let link = item.link?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty { return link }
    return "Untitled"
  }

  private func listSummary(from item: ParsedRssItem) -> String? {
    if let snippet = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty {
      return snippet
    }
    let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if let link = item.link?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty, link != title {
      return link
    }
    return nil
  }

  private func htmlBody(from item: ParsedRssItem) -> String {
    if let html = item.contentHTML?.trimmingCharacters(in: .whitespacesAndNewlines), !html.isEmpty {
      return html
    }
    if let snippet = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty {
      return "<p>\(escapeHtml(snippet))</p>"
    }
    return "<p></p>"
  }

  private func escapeHtml(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }
}
