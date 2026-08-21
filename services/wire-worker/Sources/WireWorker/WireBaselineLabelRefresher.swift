import Crypto
import Foundation

struct WireBaselineLabelRefresher: WireBaselineLabelRefreshing {
  private struct LabelIdentity: Hashable, Sendable {
    let sourceDID: String
    let subjectURI: String
    let value: String
  }

  let store: any WireBaselineLabelStore
  let queryClient: any WireLabelQuerying
  let labelers: [WireLabelerEndpoint]
  let candidateLimit: Int
  let maximumAge: TimeInterval
  var refreshTimeout: Duration = .seconds(45)

  func refresh(asOf: Date) async throws {
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { try await performRefresh(asOf: asOf) }
      tasks.addTask {
        try await Task.sleep(for: refreshTimeout)
        throw WireLabelQueryError.refreshTimedOut
      }
      _ = try await tasks.next()
      tasks.cancelAll()
    }
  }

  private func performRefresh(asOf: Date) async throws {
    let targets = try await store.loadTargets(limit: candidateLimit, asOf: asOf)
    var canonicalKeysBySubject: [String: Set<String>] = [:]
    for target in targets {
      if let representativeURI = target.representativeURI, !representativeURI.isEmpty {
        canonicalKeysBySubject[representativeURI, default: []].insert(target.canonicalKey)
      }
      if let authorDID = target.authorDID, !authorDID.isEmpty {
        canonicalKeysBySubject[authorDID, default: []].insert(target.canonicalKey)
      }
    }

    let subjects = canonicalKeysBySubject.keys.sorted()
    var batches = stride(from: 0, to: subjects.count, by: 25).map {
      Array(subjects[$0..<min($0 + 25, subjects.count)])
    }
    // queryLabels requires at least one pattern. Even an empty corpus must prove that every
    // configured baseline authority is reachable before recording a successful refresh.
    if batches.isEmpty { batches = [["did:example:the-social-wire-label-probe"]] }
    var records: [WireLabelQueryRecord] = []
    for labeler in labelers {
      for groupStart in stride(from: 0, to: batches.count, by: 4) {
        let group = Array(batches[groupStart..<min(groupStart + 4, batches.count)])
        let pages = try await withThrowingTaskGroup(
          of: [WireLabelQueryRecord].self,
          returning: [[WireLabelQueryRecord]].self
        ) { tasks in
          for batch in group {
            tasks.addTask {
              try await Self.queryAllPages(
                client: queryClient,
                labeler: labeler,
                uriPatterns: batch
              )
            }
          }
          var results: [[WireLabelQueryRecord]] = []
          for try await result in tasks { results.append(result) }
          return results
        }
        records.append(contentsOf: pages.flatMap { $0 })
      }
    }

    var latest: [LabelIdentity: (record: WireLabelQueryRecord, createdAt: Date)] = [:]
    let configuredSources = Set(labelers.map(\.sourceDID))
    for record in records {
      guard configuredSources.contains(record.sourceDID) else {
        throw WireLabelQueryError.incompleteResponse
      }
      guard let createdAt = Self.parseDate(record.createdAt) else {
        throw WireLabelQueryError.invalidResponse
      }
      let identity = LabelIdentity(
        sourceDID: record.sourceDID,
        subjectURI: record.subjectURI,
        value: record.value
      )
      if let current = latest[identity] {
        if current.createdAt > createdAt { continue }
        if current.createdAt == createdAt, current.record.negated || !record.negated { continue }
      }
      latest[identity] = (record, createdAt)
    }

    let fallbackExpiry = asOf.addingTimeInterval(7 * 24 * 60 * 60)
    var labels: [WireBaselineLabel] = []
    for value in latest.values {
      let record = value.record
      guard let mapping = Self.mapping(for: record.value), !record.negated,
        let canonicalKeys = canonicalKeysBySubject[record.subjectURI]
      else { continue }
      let appliedAt = value.createdAt
      let expiresAt: Date
      if let rawExpiry = record.expiresAt {
        guard let parsedExpiry = Self.parseDate(rawExpiry) else {
          throw WireLabelQueryError.invalidResponse
        }
        expiresAt = min(parsedExpiry, fallbackExpiry)
      } else {
        expiresAt = fallbackExpiry
      }
      guard expiresAt > asOf else { continue }
      for canonicalKey in canonicalKeys {
        labels.append(
          WireBaselineLabel(
            canonicalKey: canonicalKey,
            labelKey: mapping.key,
            labelValue: mapping.value,
            source: Self.sourceKey(for: record),
            appliedAt: appliedAt,
            expiresAt: expiresAt
          )
        )
      }
    }

    try await store.replaceSnapshot(
      labels: labels,
      labelers: labelers,
      refreshedCanonicalKeys: Array(Set(targets.map(\.canonicalKey))).sorted(),
      targetCount: targets.count,
      refreshedAt: asOf
    )
    try await store.verifyFresh(labelers: labelers, asOf: asOf, maximumAge: maximumAge)
  }

  private static func queryAllPages(
    client: any WireLabelQuerying,
    labeler: WireLabelerEndpoint,
    uriPatterns: [String]
  ) async throws -> [WireLabelQueryRecord] {
    var cursor: String?
    var records: [WireLabelQueryRecord] = []
    for _ in 0..<20 {
      let page = try await client.query(
        labeler: labeler,
        uriPatterns: uriPatterns,
        cursor: cursor
      )
      records.append(contentsOf: page.labels)
      guard let next = page.cursor, !next.isEmpty else { return records }
      guard next != cursor else { throw WireLabelQueryError.repeatedCursor }
      cursor = next
    }
    throw WireLabelQueryError.paginationLimit
  }

  private static func mapping(for value: String) -> (key: String, value: String)? {
    switch value.lowercased() {
    case "!takedown", "!suspend", "dmca-violation": ("moderation", "block")
    case "!hide": ("visibility", "exclude")
    case "spam": ("moderation", "spam")
    case "adult", "porn", "sexual", "nudity": ("moderation", "adult")
    case "graphic", "graphic-media": ("moderation", "graphic")
    default: nil
    }
  }

  private static func sourceKey(for record: WireLabelQueryRecord) -> String {
    let subjectDigest = SHA256.hash(data: Data(record.subjectURI.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "\(record.sourceDID)|\(subjectDigest)|\(record.value.lowercased())"
  }

  private static func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}
