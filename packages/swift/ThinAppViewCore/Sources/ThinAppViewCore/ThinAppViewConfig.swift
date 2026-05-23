import Foundation

/// Environment-driven configuration for the GDPR-safe thin AppView index.
public struct ThinAppViewConfig: Sendable {
public static let contentCollections: [String] = [
    "site.standard.document",
    "com.standard.document",
    "site.standard.entry",
    "com.standard.entry",
  ]

public static let readStateCollection = "com.thesocialwire.entryReadState"

public static let defaultRelayWebSocketURL =
    "wss://jetstream2.us-east.bsky.network/subscribe?wantedCollections=site.standard.document&wantedCollections=com.standard.document&wantedCollections=site.standard.entry&wantedCollections=com.standard.entry&wantedCollections=com.thesocialwire.entryReadState&wantedCollections=app.skyreader.feed.subscription"

public let enabled: Bool
public let relayWebSocketURL: String
public let contentRetentionSeconds: TimeInterval
public let readMarkRetentionSeconds: TimeInterval
public let maxEnrollAuthors: Int
  public let maxEnrollRecordsPerAuthor: Int
  public let maxEnrollConcurrency: Int
  public let proactiveBackfillEnabled: Bool
  public let proactiveBackfillIntervalSeconds: TimeInterval
  public let proactiveBackfillAuthorLimit: Int
  public let maxRssItemsPerFeed: Int
  public let rssFeedPollEnabled: Bool
  public let rssFeedPollIntervalSeconds: TimeInterval
  public let rssFeedPollFeedLimit: Int

public static func fromEnvironment(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) -> ThinAppViewConfig {
    ThinAppViewConfig(
      enabled: Self.truthyFlag(env["ENABLE_THIN_APPVIEW"]),
      relayWebSocketURL: env["THIN_APPVIEW_RELAY_WS_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty ?? defaultRelayWebSocketURL,
      contentRetentionSeconds: Self.seconds(env["THIN_APPVIEW_CONTENT_TTL_SECONDS"], default: 30 * 24 * 60 * 60),
      readMarkRetentionSeconds: Self.seconds(env["THIN_APPVIEW_READ_MARK_TTL_SECONDS"], default: 180 * 24 * 60 * 60),
      maxEnrollAuthors: Self.int(env["THIN_APPVIEW_MAX_ENROLL_AUTHORS"], default: 500),
      maxEnrollRecordsPerAuthor: Self.int(env["THIN_APPVIEW_MAX_ENROLL_RECORDS_PER_AUTHOR"], default: 2_000),
      maxEnrollConcurrency: Self.int(env["THIN_APPVIEW_MAX_ENROLL_CONCURRENCY"], default: 4),
      proactiveBackfillEnabled: Self.truthyFlag(env["THIN_APPVIEW_PROACTIVE_BACKFILL_ENABLED"], defaultWhenUnset: true),
      proactiveBackfillIntervalSeconds: Self.seconds(
        env["THIN_APPVIEW_PROACTIVE_BACKFILL_INTERVAL_SECONDS"],
        default: 15 * 60
      ),
      proactiveBackfillAuthorLimit: Self.int(env["THIN_APPVIEW_PROACTIVE_BACKFILL_AUTHOR_LIMIT"], default: 40),
      maxRssItemsPerFeed: Self.int(env["THIN_APPVIEW_MAX_RSS_ITEMS_PER_FEED"], default: 200),
      rssFeedPollEnabled: Self.truthyFlag(env["THIN_APPVIEW_RSS_FEED_POLL_ENABLED"], defaultWhenUnset: true),
      rssFeedPollIntervalSeconds: Self.seconds(env["THIN_APPVIEW_RSS_FEED_POLL_INTERVAL_SECONDS"], default: 30 * 60),
      rssFeedPollFeedLimit: Self.int(env["THIN_APPVIEW_RSS_FEED_POLL_FEED_LIMIT"], default: 20)
    )
  }

public static let disabled = ThinAppViewConfig(
    enabled: false,
    relayWebSocketURL: defaultRelayWebSocketURL,
    contentRetentionSeconds: 30 * 24 * 60 * 60,
    readMarkRetentionSeconds: 180 * 24 * 60 * 60,
    maxEnrollAuthors: 500,
    maxEnrollRecordsPerAuthor: 2_000,
    maxEnrollConcurrency: 4,
    proactiveBackfillEnabled: false,
    proactiveBackfillIntervalSeconds: 15 * 60,
    proactiveBackfillAuthorLimit: 40,
    maxRssItemsPerFeed: 200,
    rssFeedPollEnabled: false,
    rssFeedPollIntervalSeconds: 30 * 60,
    rssFeedPollFeedLimit: 20
  )

  private static func truthyFlag(_ value: String?, defaultWhenUnset: Bool = false) -> Bool {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !trimmed.isEmpty
    else { return defaultWhenUnset }
    return ["1", "true", "yes", "on"].contains(trimmed)
  }

  private static func seconds(_ raw: String?, default defaultValue: TimeInterval) -> TimeInterval {
    guard let raw, let parsed = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 else {
      return defaultValue
    }
    return parsed
  }

  private static func int(_ raw: String?, default defaultValue: Int) -> Int {
    guard let raw, let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 else {
      return defaultValue
    }
    return parsed
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
