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
    let feed = RssFeedParser(data: Data(buffer: body), feedURL: normalizedFeedUrl).parse()
    let capped = Array(feed.items.prefix(config.maxRssItemsPerFeed))
    let now = Date()
    var indexed = 0
    var canonicalToURI: [String: String] = [:]

    for item in capped {
      let stableKey = RssFeedIdentity.stableItemKey(from: item)
      let uri = RssFeedIdentity.rssEntryId(normalizedFeedUrl: normalizedFeedUrl, stableItemKey: stableKey)
      if let link = item.link?.trimmingCharacters(in: .whitespacesAndNewlines),
         !link.isEmpty,
         let canonical = RssFeedIdentity.canonicalArticleUrl(link)
      {
        if let existingURI = canonicalToURI[canonical], existingURI != uri {
          try? await store.deleteContentItem(uri: existingURI)
        }
        canonicalToURI[canonical] = uri
      }
      let createdAt = RenderFieldExtractor.createdAtDate(
        from: [:],
        fallback: ContentRenderFields(title: item.title, publishedAt: item.publishedAtISO)
      )
      let listSummary = listSummary(from: item)
      let htmlBody = htmlBody(from: item)
      let articleUrl: String? = {
        guard let link = item.link?.trimmingCharacters(in: .whitespacesAndNewlines),
              !link.isEmpty
        else { return nil }
        return RssFeedIdentity.canonicalArticleUrl(link)
      }()
      let render = ContentRenderFields(
        title: displayTitle(from: item),
        publishedAt: item.publishedAtISO,
        summary: listSummary,
        thumbnailUrl: item.thumbnailUrl,
        contentHtml: htmlBody,
        articleUrl: articleUrl
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

    try await cleanupDuplicatePublicationSiteRows(normalizedFeedUrl: normalizedFeedUrl)

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

  private func cleanupDuplicatePublicationSiteRows(normalizedFeedUrl: String) async throws {
    let rows = try await store.listContentItemsForPublicationSite(
      authorDid: RssFeedLexicons.rssAuthorDid,
      publicationSite: normalizedFeedUrl,
      limit: 1_000
    )
    guard rows.count > 1 else { return }

    var canonicalToURI: [String: String] = [:]
    var toDelete: Set<String> = []

    for row in rows {
      guard
        let canonical = RssFeedIdentity.canonicalLink(
          forEntryId: row.uri,
          renderJSON: row.renderJSON,
          summary: nil
        )
      else { continue }

      if let existingURI = canonicalToURI[canonical] {
        if RssFeedIdentity.isPreferredRssEntryURI(row.uri, over: existingURI) {
          toDelete.insert(existingURI)
          canonicalToURI[canonical] = row.uri
        } else {
          toDelete.insert(row.uri)
        }
      } else {
        canonicalToURI[canonical] = row.uri
      }
    }

    for uri in toDelete {
      try await store.deleteContentItem(uri: uri)
    }

    let keptTitlePublished = Set(
      canonicalToURI.values.compactMap { uri in
        rows.first(where: { $0.uri == uri }).flatMap(titlePublishedKey(from:))
      }
    )
    guard !keptTitlePublished.isEmpty else { return }

    for row in rows {
      guard !toDelete.contains(row.uri), !canonicalToURI.values.contains(row.uri) else { continue }
      guard let key = titlePublishedKey(from: row), keptTitlePublished.contains(key) else { continue }
      try await store.deleteContentItem(uri: row.uri)
    }
  }

  private func titlePublishedKey(from row: (uri: String, renderJSON: String)) -> String? {
    guard
      let data = row.renderJSON.data(using: .utf8),
      let render = try? JSONDecoder().decode(ContentRenderFields.self, from: data)
    else { return nil }
    let title = render.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !title.isEmpty else { return nil }
    guard let publishedAt = ThinAppViewQuerySupport.parseISO8601Date(render.publishedAt) else { return nil }
    return "\(title)|\(Int(publishedAt.timeIntervalSince1970))"
  }
}
