// Copy unchanged into each exact revision's Tests/WireWorkerTests directory.
// Run only against a fresh, migrated, disposable loopback database on a non-5432 port.
// The enclosing runner must isolate the PostgreSQL cluster from other writers and
// enforce an outer process timeout. LSN deltas are cluster-wide, not database-local.
import Foundation
import Logging
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

@Suite("Synthetic Wire write amplification replay", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["WIRE_WRITE_REPLAY_DATABASE_URL"] != nil))
struct WireWriteAmplificationReplayTests {
  @Test("repeat real inbox projections and embedded metadata without inventing activity")
  func replay() async throws {
    let environment = ProcessInfo.processInfo.environment
    let rawURL = try #require(environment["WIRE_WRITE_REPLAY_DATABASE_URL"])
    let output = try #require(environment["WIRE_WRITE_REPLAY_OUTPUT"])
    let revision = try #require(environment["WIRE_WRITE_REPLAY_REVISION"])
    try Self.validate(rawURL: rawURL, output: output, revision: revision)
    var logger = Logger(label: "wire.synthetic-write-replay")
    logger.logLevel = .warning
    let config = try PostgresWireConfig.make(from: rawURL, maximumConnections: 2, logger: logger)
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let trial = WriteReplayTrial(pool: pool, logger: logger)
    let evidence = try await trial.run(revision: revision)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    try encoder.encode(evidence).write(to: URL(fileURLWithPath: output), options: .atomic)
  }

  private static func validate(rawURL: String, output: String, revision: String) throws {
    guard let url = URLComponents(string: rawURL),
      ["postgres", "postgresql"].contains(url.scheme ?? ""),
      ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? ""),
      let port = url.port, port > 0, port != 5432, url.fragment == nil,
      url.path.range(of: "^/tsw92_write_[a-f0-9]{12}$", options: .regularExpression) != nil,
      (url.queryItems ?? []).allSatisfy({ $0.name == "sslmode" && $0.value == "disable" }),
      (url.queryItems ?? []).count <= 1,
      revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
      output.hasPrefix("/"), !FileManager.default.fileExists(atPath: output)
    else { throw WriteReplayError.unsafeConfiguration }
  }
}

private struct WriteReplayTrial {
  let pool: PostgresClient
  let logger: Logger
  // Fixed, identical times and identities across revisions. No public traffic.
  let asOf = Date(timeIntervalSince1970: 1_788_782_460)
  let url = "https://wire-write-replay.invalid/story"
  let repo = "did:example:wire-write-replay"
  let environment = "synthetic-write-replay"
  var key: String { WireCanonicalizer.canonicalize(url)!.canonicalKey }
  var sourceURI: String { "at://\(repo)/site.standard.document/record" }

  func run(revision: String) async throws -> WriteReplayEvidence {
    guard try await scalar("""
      SELECT (SELECT COUNT(*) FROM wire_items) + (SELECT COUNT(*) FROM wire_item_aliases)
        + (SELECT COUNT(*) FROM wire_link_metadata_cache) + (SELECT COUNT(*) FROM wire_ingestion_inbox)
        + (SELECT COUNT(*) FROM wire_standard_record_fences)
        + (SELECT COUNT(*) FROM wire_signal_events) + (SELECT COUNT(*) FROM wire_active_actors)
      """) == 0 else { throw WriteReplayError.nonemptyDatabase }
    let started = ContinuousClock.now
    let processor = try PostgresWireInboxProcessor(pool: pool, logger: logger,
      actorSecret: String(repeating: "s", count: 32), batchSize: 1, maximumConcurrentEvents: 1,
      sourceScope: WireInboxSourceScope(environment: environment, sourceGenerations: ["live"]))
    try await insert(sequence: 1, snapshot: false, asOf: asOf, title: "Synthetic Article")
    guard try await processor.process(asOf: asOf) == 1 else { throw WriteReplayError.notApplied }
    let original = try await state()
    guard original.lastSignal == asOf, original.title == "Synthetic Article" else {
      throw WriteReplayError.changedSemantics
    }
    let cache = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
    let metadata = WireLinkMetadata(canonicalURL: url, title: "Embedded Synthetic Article",
      description: "Synthetic cache payload", imageURL: nil, siteName: nil, authorName: nil,
      publishedAt: nil, iconURL: nil, etag: nil, lastModified: nil, source: .embeddedCard)
    try await cache.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: asOf)
    let retryDeadline = asOf.addingTimeInterval(10_000)
    try await pool.query("""
      UPDATE wire_link_metadata_cache SET status = 'retry', retry_after = \(retryDeadline), failure_count = 3
      WHERE canonical_key = \(key)
      """, logger: logger)
    var phases: [WriteReplayPhase] = []
    var sequence: Int64 = 2
    for varying in [false, true] {
      var previous = try await state()
      var itemChanges = 0
      var aliasChanges = 0
      let before = try await lsn()
      let phaseStart = ContinuousClock.now
      for index in 0..<100 {
        try budget(started)
        let time = varying ? asOf.addingTimeInterval(Double(index + 1) * 10) : asOf
        try await insert(sequence: sequence, snapshot: true, asOf: time, title: "Synthetic Article")
        guard try await processor.process(asOf: time) == 1 else { throw WriteReplayError.notApplied }
        let current = try await state()
        itemChanges += current.itemVersion != previous.itemVersion ? 1 : 0
        aliasChanges += current.aliasVersion != previous.aliasVersion ? 1 : 0
        guard current.lastSignal == original.lastSignal, current.lastSeen == time, current.title == original.title,
          current.sourceFields == original.sourceFields,
          current.itemExpiry >= time.addingTimeInterval(WireDataPolicy.itemRetention),
          current.itemExpiry <= time.addingTimeInterval(WireDataPolicy.itemRetention + 3600),
          current.aliasExpiry >= time.addingTimeInterval(WireDataPolicy.itemRetention),
          current.aliasExpiry <= time.addingTimeInterval(WireDataPolicy.itemRetention + 3600)
        else { throw WriteReplayError.changedSemantics }
        previous = current
        sequence += 1
      }
      let after = try await lsn()
      phases.append(WriteReplayPhase(name: varying ? "inbox-varying-within-hour" : "inbox-same-as-of",
        iterations: 100, walBytes: try await walDelta(before: before, after: after),
        durationMilliseconds: milliseconds(phaseStart.duration(to: .now)),
        itemRowVersionsChanged: itemChanges, trackedAliasRowVersionsChanged: aliasChanges,
        metadataRowVersionsChanged: 0))
    }
    for varying in [false, true] {
      var previous = try await metadataState()
      var changes = 0
      let before = try await lsn()
      let phaseStart = ContinuousClock.now
      for index in 0..<100 {
        try budget(started)
        let time = varying ? asOf.addingTimeInterval(Double(index + 1) * 10) : asOf
        try await cache.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: time)
        let current = try await metadataState()
        changes += current.version != previous.version ? 1 : 0
        guard current.title == metadata.title, current.status == "retry", current.failureCount == 3,
          current.staleUntil >= time.addingTimeInterval(7 * 86400),
          current.staleUntil <= time.addingTimeInterval(7 * 86400 + 3600)
        else { throw WriteReplayError.changedSemantics }
        previous = current
      }
      let after = try await lsn()
      phases.append(WriteReplayPhase(name: varying ? "metadata-varying-within-hour" : "metadata-same-as-of",
        iterations: 100, walBytes: try await walDelta(before: before, after: after),
        durationMilliseconds: milliseconds(phaseStart.duration(to: .now)),
        itemRowVersionsChanged: 0, trackedAliasRowVersionsChanged: 0, metadataRowVersionsChanged: changes))
    }
    // A truly newer live record still changes source text and ranking activity.
    // Its publication signal replaces the prior source-URI signal; actor activity
    // counts both real commits while retained signal rows contain only the newest.
    let freshTime = asOf.addingTimeInterval(1200)
    try await insert(sequence: sequence, snapshot: false, asOf: freshTime, title: "Updated Synthetic Article", newer: true)
    guard try await processor.process(asOf: freshTime) == 1 else { throw WriteReplayError.notApplied }
    let final = try await state()
    let applied = try await scalar("SELECT COUNT(*) FROM wire_ingestion_inbox WHERE status = 'applied'")
    let signals = try await scalar("SELECT COUNT(*) FROM wire_signal_events WHERE source_uri = \(sourceURI)")
    guard applied == 202, final.lastSignal == freshTime, final.lastSeen == freshTime,
      final.title == "Updated Synthetic Article", signals == 1,
      try await scalar("SELECT COALESCE(SUM(public_signal_count), 0)::bigint FROM wire_active_actors") == 2,
      try await scalar("SELECT COUNT(*) FROM wire_ingestion_inbox WHERE status <> 'applied'") == 0
    else { throw WriteReplayError.changedSemantics }
    let finalMetadata = try await metadataState()
    return WriteReplayEvidence(revision: revision, fixedAsOf: asOf.timeIntervalSince1970,
      phases: phases, appliedInboxRows: applied, realSignalRows: signals, finalItem: final,
      metadata: finalMetadata, initialMetadataRetryAt: retryDeadline.timeIntervalSince1970)
  }

  func insert(sequence: Int64, snapshot: Bool, asOf processTime: Date, title: String, newer: Bool = false) async throws {
    let revision = newer ? "3m22222222225" : "3m22222222223"
    let cid = newer ? "bafyreif2o444riqelx6ezgzlcnmfimbxdd6t676cozuwmwf5tkx674cyta"
      : "bafyreidvz67ncib33pu5xmu4a27v3ja7k2dtctflvutfo3ml7a4p4jptz4"
    let record = ["$type": "site.standard.document", "url": url, "title": title,
      "publishedAt": asOf.addingTimeInterval(-86400).ISO8601Format()]
    let document: [String: Any] = snapshot
      ? ["snapshot": ["record": record, "cid": cid, "rev": revision]]
      : ["commit": ["record": record, "rev": revision]]
    let payload = String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    try await pool.query("""
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, record_key, record_cid, repo_rev, payload, event_time, next_attempt_at)
      VALUES (\(environment), 'live', \(sequence), 'https://pds.wire-write-replay.invalid',
        \(snapshot ? "pds_record_snapshot" : "jetstream_v2_seq"), \(snapshot ? "snapshot" : "commit"),
        \(repo), 'site.standard.document', 'update', 'record', \(cid), \(revision), \(payload)::jsonb,
        \(newer ? processTime : asOf), \(processTime))
      """, logger: logger)
  }

  func state() async throws -> WriteReplayItemState {
    let rows = try await pool.query("""
      SELECT item.ctid::text, alias.ctid::text, item.title, item.last_signal_at, item.last_seen_at,
        item.expires_at, alias.expires_at,
        jsonb_build_array(item.canonical_url, item.representative_uri, item.author_key,
          item.source_domain, item.source_name, item.summary, item.published_at,
          item.source_confidence, item.eligible, item.target_kind, item.presentation_snapshot)::text
      FROM wire_items item JOIN wire_item_aliases alias ON alias.canonical_key = item.canonical_key
      WHERE item.canonical_key = \(key) AND alias.alias_key = \(sourceURI)
      """, logger: logger)
    for try await row in rows {
      let value = try row.decode((String, String, String, Date, Date, Date, Date, String).self)
      return WriteReplayItemState(itemVersion: value.0, aliasVersion: value.1, title: value.2,
        lastSignal: value.3, lastSeen: value.4, itemExpiry: value.5, aliasExpiry: value.6, sourceFields: value.7)
    }
    throw WriteReplayError.missingRow
  }

  func metadataState() async throws -> WriteReplayMetadataState {
    for try await row in try await pool.query("""
      SELECT ctid::text, title, status, failure_count, retry_after, stale_until
      FROM wire_link_metadata_cache WHERE canonical_key = \(key)
      """, logger: logger) {
      let value = try row.decode((String, String, String, Int, Date, Date).self)
      return WriteReplayMetadataState(version: value.0, title: value.1, status: value.2,
        failureCount: value.3, retryAt: value.4, staleUntil: value.5)
    }
    throw WriteReplayError.missingRow
  }

  func scalar(_ query: PostgresQuery) async throws -> Int64 {
    for try await row in try await pool.query(query, logger: logger) { return try row.decode(Int64.self) }
    throw WriteReplayError.missingRow
  }

  func lsn() async throws -> String {
    for try await row in try await pool.query("SELECT pg_current_wal_insert_lsn()::text", logger: logger) {
      return try row.decode(String.self)
    }
    throw WriteReplayError.missingRow
  }

  func walDelta(before: String, after: String) async throws -> Int64 {
    try await scalar("SELECT pg_wal_lsn_diff(\(after)::pg_lsn, \(before)::pg_lsn)::bigint")
  }

  func budget(_ start: ContinuousClock.Instant) throws {
    try Task.checkCancellation()
    guard start.duration(to: .now) < .seconds(120) else { throw WriteReplayError.deadline }
  }

  func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
  }
}

private enum WriteReplayError: Error {
  case unsafeConfiguration, nonemptyDatabase, notApplied, changedSemantics, missingRow, deadline
}

private struct WriteReplayPhase: Codable {
  let name: String
  let iterations: Int
  let walBytes: Int64
  let durationMilliseconds: Double
  let itemRowVersionsChanged: Int
  let trackedAliasRowVersionsChanged: Int
  let metadataRowVersionsChanged: Int
}

private struct WriteReplayItemState: Codable {
  let itemVersion: String
  let aliasVersion: String
  let title: String
  let lastSignal: Date
  let lastSeen: Date
  let itemExpiry: Date
  let aliasExpiry: Date
  let sourceFields: String
}

private struct WriteReplayMetadataState: Codable {
  let version: String
  let title: String
  let status: String
  let failureCount: Int
  let retryAt: Date
  let staleUntil: Date
}

private struct WriteReplayEvidence: Encodable {
  let kind = "synthetic-real-write-path-replay"
  let fixtureVersion = 1
  let disclaimer = "Synthetic shared-item hot-key replay, not a Production workload or savings claim. Run each revision in a fresh migrated database on an otherwise idle disposable cluster. WAL includes identical inbox bookkeeping and all real processor side effects; ctid comparisons count observed tuple replacements for the item, its AT-URI alias, and metadata row, not every WAL record or the separate URL alias. Expiry may extend by up to one hour; preservation of metadata retry backoff is an intentional after-only change."
  let revision: String
  let fixedAsOf: Double
  let phases: [WriteReplayPhase]
  let appliedInboxRows: Int64
  let realSignalRows: Int64
  let finalItem: WriteReplayItemState
  let metadata: WriteReplayMetadataState
  let initialMetadataRetryAt: Double
}
