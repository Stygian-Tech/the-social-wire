import Foundation

/// Environment-driven configuration for the GDPR-safe thin AppView index.
struct ThinAppViewConfig: Sendable {
  static let contentCollections: [String] = [
    "site.standard.document",
    "com.standard.document",
    "site.standard.entry",
    "com.standard.entry",
  ]

  static let readStateCollection = "com.thesocialwire.entryReadState"

  static let defaultRelayWebSocketURL =
    "wss://jetstream2.us-east.bsky.network/subscribe?wantedCollections=site.standard.document&wantedCollections=com.standard.document&wantedCollections=site.standard.entry&wantedCollections=com.standard.entry&wantedCollections=com.thesocialwire.entryReadState"

  let enabled: Bool
  let relayWebSocketURL: String
  let contentRetentionSeconds: TimeInterval
  let readMarkRetentionSeconds: TimeInterval
  let maxEnrollAuthors: Int

  static func fromEnvironment(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) -> ThinAppViewConfig {
    ThinAppViewConfig(
      enabled: Self.truthyFlag(env["ENABLE_THIN_APPVIEW"]),
      relayWebSocketURL: env["THIN_APPVIEW_RELAY_WS_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty ?? defaultRelayWebSocketURL,
      contentRetentionSeconds: Self.seconds(env["THIN_APPVIEW_CONTENT_TTL_SECONDS"], default: 30 * 24 * 60 * 60),
      readMarkRetentionSeconds: Self.seconds(env["THIN_APPVIEW_READ_MARK_TTL_SECONDS"], default: 180 * 24 * 60 * 60),
      maxEnrollAuthors: Self.int(env["THIN_APPVIEW_MAX_ENROLL_AUTHORS"], default: 500)
    )
  }

  static let disabled = ThinAppViewConfig(
    enabled: false,
    relayWebSocketURL: defaultRelayWebSocketURL,
    contentRetentionSeconds: 30 * 24 * 60 * 60,
    readMarkRetentionSeconds: 180 * 24 * 60 * 60,
    maxEnrollAuthors: 500
  )

  private static func truthyFlag(_ value: String?) -> Bool {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !trimmed.isEmpty
    else { return false }
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
