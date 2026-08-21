import Foundation
import Logging
import PostgresNIO
import WireCore

struct PostgresWireInboxProcessor: Sendable {
  private struct InboxEvent: Sendable {
    let environment: String
    let sourceGeneration: String
    let sequence: Int64
    let eventKind: String
    let repoDID: String
    let collection: String?
    let operation: String?
    let recordKey: String?
    let payloadJSON: String
    let eventTime: Date
    let leaseToken: String
    let attemptCount: Int

    var sourceURI: String? {
      guard let collection, let recordKey else { return nil }
      return "at://\(repoDID)/\(collection)/\(recordKey)"
    }
  }

  private enum ApplyError: Error {
    case unresolvedReference
    case malformed
  }

  let pool: PostgresClient
  let logger: Logger
  let actorHasher: WireActorHasher
  let batchSize: Int

  init(pool: PostgresClient, logger: Logger, actorSecret: String, batchSize: Int = 1_000) throws {
    self.pool = pool
    self.logger = logger
    self.actorHasher = try WireActorHasher(secret: Data(actorSecret.utf8))
    self.batchSize = max(1, min(batchSize, 5_000))
  }

  func process(asOf: Date) async throws -> Int {
    let events = try await claim(asOf: asOf)
    for event in events {
      do {
        try await apply(event, asOf: asOf)
        try await finish(event, status: "applied", retryAt: asOf, reason: nil, asOf: asOf)
      } catch ApplyError.unresolvedReference {
        if asOf.timeIntervalSince(event.eventTime) < 24 * 3_600 {
          try await finish(
            event,
            status: "retry",
            retryAt: asOf.addingTimeInterval(30),
            reason: "unresolved_subject",
            asOf: asOf
          )
        } else {
          try await finish(
            event,
            status: "dead_letter",
            retryAt: asOf,
            reason: "unresolved_subject_expired",
            asOf: asOf
          )
        }
      } catch ApplyError.malformed {
        try await finish(
          event,
          status: "dead_letter",
          retryAt: asOf,
          reason: "malformed_event",
          asOf: asOf
        )
      } catch {
        let terminal = event.attemptCount >= 8
        try await finish(
          event,
          status: terminal ? "dead_letter" : "retry",
          retryAt: terminal ? asOf : asOf.addingTimeInterval(60),
          reason: String(reflecting: error).prefix(500).description,
          asOf: asOf
        )
      }
    }
    try await pruneActiveGraph(asOf: asOf)
    try await refreshCommunitiesIfNeeded(asOf: asOf)
    try await refreshRollups(asOf: asOf)
    return events.count
  }

  private func claim(asOf: Date) async throws -> [InboxEvent] {
    let token = UUID().uuidString.lowercased()
    let leaseUntil = asOf.addingTimeInterval(120)
    let rows = try await pool.query(
      """
      WITH candidates AS (
        SELECT environment, source_generation, seq
        FROM wire_ingestion_inbox candidate
        WHERE (((candidate.status IN ('pending', 'retry') AND candidate.next_attempt_at <= \(asOf))
          OR (candidate.status = 'leased' AND candidate.lease_expires_at <= \(asOf))))
          AND NOT EXISTS (
            SELECT 1 FROM wire_ingestion_inbox earlier
            WHERE earlier.environment = candidate.environment
              AND earlier.source_generation = candidate.source_generation
              AND earlier.repo_did = candidate.repo_did
              AND earlier.seq < candidate.seq
              AND earlier.status IN ('pending', 'leased', 'retry')
          )
        ORDER BY seq
        FOR UPDATE SKIP LOCKED
        LIMIT \(batchSize)
      )
      UPDATE wire_ingestion_inbox inbox
      SET status = 'leased', lease_owner = 'wire-worker', lease_token = \(token),
          lease_expires_at = \(leaseUntil), attempt_count = attempt_count + 1,
          updated_at = \(asOf)
      FROM candidates
      WHERE inbox.environment = candidates.environment
        AND inbox.source_generation = candidates.source_generation
        AND inbox.seq = candidates.seq
      RETURNING inbox.environment, inbox.source_generation, inbox.seq, inbox.event_kind,
                inbox.repo_did, inbox.collection, inbox.operation, inbox.record_key,
                inbox.payload::text, inbox.event_time, inbox.lease_token, inbox.attempt_count
      """,
      logger: logger
    )
    var result: [InboxEvent] = []
    for try await row in rows {
      let value = try row.decode(
        (String, String, Int64, String, String, String?, String?, String?, String, Date, String, Int).self
      )
      result.append(
        InboxEvent(
          environment: value.0,
          sourceGeneration: value.1,
          sequence: value.2,
          eventKind: value.3,
          repoDID: value.4,
          collection: value.5,
          operation: value.6,
          recordKey: value.7,
          payloadJSON: value.8,
          eventTime: value.9,
          leaseToken: value.10,
          attemptCount: value.11
        )
      )
    }
    return result.sorted { $0.sequence < $1.sequence }
  }

  private func apply(_ event: InboxEvent, asOf: Date) async throws {
    if event.eventKind == "account" {
      try await applyAccountLifecycle(event, asOf: asOf)
      return
    }
    guard event.eventKind == "commit", let collection = event.collection,
      let operation = event.operation, let sourceURI = event.sourceURI
    else { return }
    if operation == "delete" {
      try await retract(sourceURI: sourceURI, asOf: asOf)
      return
    }
    guard operation == "create" || operation == "update",
      let document = try JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)) as? [String: Any],
      let commit = document["commit"] as? [String: Any],
      let record = commit["record"] as? [String: Any]
    else { throw ApplyError.malformed }

    switch collection {
    case "site.standard.document", "site.standard.entry":
      try await applyArticle(record: record, event: event, sourceURI: sourceURI, asOf: asOf)
    case "app.bsky.feed.post":
      try await applyPost(record: record, event: event, sourceURI: sourceURI, asOf: asOf)
    case "site.standard.graph.recommend":
      try await applyReferenceSignal(
        record: record,
        event: event,
        sourceURI: sourceURI,
        kind: "recommendation",
        asOf: asOf
      )
    case "app.bsky.feed.like":
      try await applyReferenceSignal(
        record: record, event: event, sourceURI: sourceURI, kind: "like", asOf: asOf
      )
    case "app.bsky.feed.repost":
      try await applyReferenceSignal(
        record: record, event: event, sourceURI: sourceURI, kind: "repost", asOf: asOf
      )
    case "app.bsky.graph.follow":
      try await applyFollow(record: record, event: event, sourceURI: sourceURI, asOf: asOf)
    default:
      return
    }
  }

  private func applyArticle(
    record: [String: Any],
    event: InboxEvent,
    sourceURI: String,
    asOf: Date
  ) async throws {
    guard let rawURL = Self.firstString(record, keys: ["canonicalUrl", "url", "siteUrl"]),
      let identity = WireCanonicalizer.canonicalize(rawURL),
      let host = URL(string: identity.canonicalURL)?.host
    else { throw ApplyError.malformed }
    let title = Self.firstString(record, keys: ["title", "name"]) ?? host
    let summary = Self.firstString(record, keys: ["summary", "description", "text"])
    let thumbnail = Self.firstString(record, keys: ["thumbnail", "thumbnailUrl", "image"])
    let language = Self.primaryLanguage(Self.firstString(record, keys: ["lang", "language"]))
    let publishedAt = Self.date(Self.firstString(record, keys: ["publishedAt", "createdAt"]))
    let publicationID = Self.firstString(record, keys: ["site", "publication"])
    let authorName = Self.firstString(record, keys: ["authorName", "displayName"])
    let topicKeys = (record["tags"] as? [String] ?? []).map { $0.lowercased() }
    let actorHash = try actorHasher.hash(event.repoDID)
    try await upsertItem(
      identity: identity,
      representativeURI: sourceURI,
      authorDID: event.repoDID,
      sourceName: Self.firstString(record, keys: ["publicationName", "siteName"]) ?? host,
      host: host,
      publicationID: publicationID,
      authorName: authorName,
      topicKeys: topicKeys,
      title: title,
      summary: summary,
      thumbnail: thumbnail,
      language: language,
      publishedAt: publishedAt,
      provenance: ["standard_site"],
      confidence: 0.9,
      asOf: asOf
    )
    try await upsertAlias(alias: sourceURI, type: "at_uri", canonicalKey: identity.canonicalKey, asOf: asOf)
    try await upsertAlias(alias: identity.canonicalURL, type: "url", canonicalKey: identity.canonicalKey, asOf: asOf)
    try await upsertActor(hash: actorHash, asOf: asOf)
    try await insertSignal(
      event: event,
      canonicalKey: identity.canonicalKey,
      actorHash: actorHash,
      sourceURI: sourceURI,
      kind: "publication",
      asOf: asOf
    )
  }

  private func applyPost(
    record: [String: Any],
    event: InboxEvent,
    sourceURI: String,
    asOf: Date
  ) async throws {
    guard let rawURL = Self.externalURL(record),
      let identity = WireCanonicalizer.canonicalize(rawURL),
      let host = URL(string: identity.canonicalURL)?.host
    else { return }
    let text = Self.firstString(record, keys: ["text"])
    let title = text?.split(separator: "\n").first.map(String.init).flatMap {
      $0.isEmpty ? nil : String($0.prefix(200))
    } ?? host
    let actorHash = try actorHasher.hash(event.repoDID)
    try await upsertItem(
      identity: identity,
      representativeURI: sourceURI,
      authorDID: nil,
      sourceName: host,
      host: host,
      publicationID: nil,
      authorName: nil,
      topicKeys: [],
      title: title,
      summary: text,
      thumbnail: nil,
      language: Self.primaryLanguage(Self.firstString(record, keys: ["langs", "lang"])),
      publishedAt: Self.date(Self.firstString(record, keys: ["createdAt"])),
      provenance: [Self.containsQuote(record) ? "quote" : "direct_share"],
      confidence: 0.6,
      asOf: asOf
    )
    try await upsertAlias(alias: sourceURI, type: "at_uri", canonicalKey: identity.canonicalKey, asOf: asOf)
    try await upsertAlias(alias: identity.canonicalURL, type: "url", canonicalKey: identity.canonicalKey, asOf: asOf)
    try await upsertActor(hash: actorHash, asOf: asOf)
    let kind = Self.containsQuote(record) ? "quote" : "share"
    try await insertSignal(
      event: event,
      canonicalKey: identity.canonicalKey,
      actorHash: actorHash,
      sourceURI: sourceURI,
      kind: kind,
      asOf: asOf
    )
  }

  private func applyReferenceSignal(
    record: [String: Any],
    event: InboxEvent,
    sourceURI: String,
    kind: String,
    asOf: Date
  ) async throws {
    guard let subject = record["subject"] else { throw ApplyError.malformed }
    let subjectURI: String?
    if let string = subject as? String {
      subjectURI = string
    } else {
      subjectURI = (subject as? [String: Any])?["uri"] as? String
    }
    guard let subjectURI, let canonicalKey = try await canonicalKey(alias: subjectURI) else {
      throw ApplyError.unresolvedReference
    }
    let actorHash = try actorHasher.hash(event.repoDID)
    try await upsertActor(hash: actorHash, asOf: asOf)
    try await appendProvenance(kind, canonicalKey: canonicalKey, asOf: asOf)
    try await insertSignal(
      event: event,
      canonicalKey: canonicalKey,
      actorHash: actorHash,
      sourceURI: sourceURI,
      kind: kind,
      asOf: asOf
    )
  }

  private func applyFollow(
    record: [String: Any],
    event: InboxEvent,
    sourceURI: String,
    asOf: Date
  ) async throws {
    guard let subject = record["subject"] as? String else { throw ApplyError.malformed }
    let follower = try actorHasher.hash(event.repoDID)
    let followee = try actorHasher.hash(subject)
    guard try await isActiveActor(hash: follower, asOf: asOf) else { return }
    let expiresAt = asOf.addingTimeInterval(WireDataPolicy.followEdgeRetention)
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "DELETE FROM wire_follow_edges WHERE source_uri = \(sourceURI)",
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO wire_follow_edges
          (source_uri, follower_key_hash, followee_key_hash, observed_at, expires_at)
        VALUES (\(sourceURI), \(follower), \(followee), \(asOf), \(expiresAt))
        ON CONFLICT (follower_key_hash, followee_key_hash) DO UPDATE
        SET source_uri = EXCLUDED.source_uri, observed_at = EXCLUDED.observed_at,
            expires_at = EXCLUDED.expires_at
        """,
        logger: logger
      )
    }
    try await pool.query(
      """
      DELETE FROM wire_follow_edges edge
      WHERE edge.follower_key_hash = \(follower)
        AND edge.followee_key_hash IN (
          SELECT followee_key_hash FROM wire_follow_edges
          WHERE follower_key_hash = \(follower)
          ORDER BY observed_at DESC, followee_key_hash
          OFFSET \(WireDataPolicy.maximumFollowEdgesPerActor)
        )
      """,
      logger: logger
    )
  }

  private func applyAccountLifecycle(_ event: InboxEvent, asOf: Date) async throws {
    guard let document = try JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)) as? [String: Any],
      let account = document["account"] as? [String: Any],
      account["active"] as? Bool == false
    else { return }
    let actorHash = try actorHasher.hash(event.repoDID)
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "UPDATE wire_items SET eligible = FALSE, updated_at = \(asOf) WHERE author_key = \(event.repoDID)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_signal_events WHERE actor_key_hash = \(actorHash)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_follow_edges WHERE follower_key_hash = \(actorHash) OR followee_key_hash = \(actorHash)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_active_actors WHERE actor_key_hash = \(actorHash)",
        logger: logger
      )
    }
  }

  private func retract(sourceURI: String, asOf: Date) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "DELETE FROM wire_signal_events WHERE source_uri = \(sourceURI)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_follow_edges WHERE source_uri = \(sourceURI)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_item_aliases WHERE alias_key = \(sourceURI)",
        logger: logger
      )
      try await connection.query(
        "UPDATE wire_items SET updated_at = \(asOf) WHERE representative_uri = \(sourceURI)",
        logger: logger
      )
    }
  }

  private func upsertItem(
    identity: WireCanonicalIdentity,
    representativeURI: String,
    authorDID: String?,
    sourceName: String,
    host: String,
    publicationID: String?,
    authorName: String?,
    topicKeys: [String],
    title: String,
    summary: String?,
    thumbnail: String?,
    language: String,
    publishedAt: Date?,
    provenance: [String],
    confidence: Double,
    asOf: Date
  ) async throws {
    let provenanceJSON = String(decoding: try JSONEncoder().encode(provenance), as: UTF8.self)
    let topicsJSON = String(decoding: try JSONEncoder().encode(topicKeys), as: UTF8.self)
    let expiresAt = asOf.addingTimeInterval(WireDataPolicy.itemRetention)
    try await pool.query(
      """
      INSERT INTO wire_items
        (canonical_key, canonical_url, representative_uri, publication_id, author_key,
         source_domain, source_name, author_name, title, summary, thumbnail_url,
         language_code, topic_keys, presentation_snapshot, provenance, published_at,
         first_seen_at, last_seen_at, last_signal_at,
         source_confidence, eligible, expires_at, updated_at)
      VALUES
        (\(identity.canonicalKey), \(identity.canonicalURL), \(representativeURI), \(publicationID),
         \(authorDID), \(host), \(sourceName), \(authorName), \(title), \(summary), \(thumbnail),
         \(language), \(topicsJSON)::jsonb, '{}'::jsonb, \(provenanceJSON)::jsonb,
         \(publishedAt), \(asOf), \(asOf), \(asOf), \(confidence), TRUE, \(expiresAt), \(asOf))
      ON CONFLICT (canonical_key) DO UPDATE SET
        canonical_url = EXCLUDED.canonical_url,
        representative_uri = COALESCE(wire_items.representative_uri, EXCLUDED.representative_uri),
        publication_id = COALESCE(wire_items.publication_id, EXCLUDED.publication_id),
        author_key = COALESCE(wire_items.author_key, EXCLUDED.author_key),
        author_name = COALESCE(wire_items.author_name, EXCLUDED.author_name),
        title = CASE WHEN length(EXCLUDED.title) > length(wire_items.title)
          THEN EXCLUDED.title ELSE wire_items.title END,
        summary = COALESCE(wire_items.summary, EXCLUDED.summary),
        thumbnail_url = COALESCE(wire_items.thumbnail_url, EXCLUDED.thumbnail_url),
        language_code = CASE WHEN wire_items.language_code = 'und'
          THEN EXCLUDED.language_code ELSE wire_items.language_code END,
        topic_keys = CASE WHEN jsonb_array_length(wire_items.topic_keys) = 0
          THEN EXCLUDED.topic_keys ELSE wire_items.topic_keys END,
        provenance = (
          SELECT COALESCE(jsonb_agg(value ORDER BY value), '[]'::jsonb)
          FROM (
            SELECT DISTINCT value
            FROM jsonb_array_elements_text(wire_items.provenance || EXCLUDED.provenance)
          ) unique_provenance
        ),
        published_at = COALESCE(wire_items.published_at, EXCLUDED.published_at),
        last_seen_at = EXCLUDED.last_seen_at, last_signal_at = EXCLUDED.last_signal_at,
        source_confidence = GREATEST(wire_items.source_confidence, EXCLUDED.source_confidence),
        expires_at = GREATEST(wire_items.expires_at, EXCLUDED.expires_at), updated_at = EXCLUDED.updated_at
      """,
      logger: logger
    )
  }

  private func upsertAlias(
    alias: String,
    type: String,
    canonicalKey: String,
    asOf: Date
  ) async throws {
    try await pool.query(
      """
      INSERT INTO wire_item_aliases (alias_key, canonical_key, alias_type, expires_at)
      VALUES (\(alias), \(canonicalKey), \(type), \(asOf.addingTimeInterval(WireDataPolicy.itemRetention)))
      ON CONFLICT (alias_key) DO UPDATE SET canonical_key = EXCLUDED.canonical_key,
        expires_at = EXCLUDED.expires_at
      """,
      logger: logger
    )
  }

  private func appendProvenance(
    _ kind: String,
    canonicalKey: String,
    asOf: Date
  ) async throws {
    guard ["recommendation", "like", "repost"].contains(kind) else { return }
    try await pool.query(
      """
      UPDATE wire_items item
      SET provenance = (
        SELECT COALESCE(jsonb_agg(value ORDER BY value), '[]'::jsonb)
        FROM (
          SELECT DISTINCT value
          FROM jsonb_array_elements_text(item.provenance || to_jsonb(ARRAY[\(kind)]::text[]))
        ) unique_provenance
      ), updated_at = \(asOf)
      WHERE canonical_key = \(canonicalKey)
      """,
      logger: logger
    )
  }

  private func canonicalKey(alias: String) async throws -> String? {
    let rows = try await pool.query(
      "SELECT canonical_key FROM wire_item_aliases WHERE alias_key = \(alias) AND expires_at > NOW() LIMIT 1",
      logger: logger
    )
    for try await row in rows { return try row.decode(String.self) }
    return nil
  }

  private func upsertActor(hash: String, asOf: Date) async throws {
    try await pool.query(
      """
      INSERT INTO wire_active_actors
        (actor_key_hash, first_active_at, last_active_at, public_signal_count, expires_at)
      VALUES (\(hash), \(asOf), \(asOf), 1, \(asOf.addingTimeInterval(WireDataPolicy.activeActorRetention)))
      ON CONFLICT (actor_key_hash) DO UPDATE SET last_active_at = EXCLUDED.last_active_at,
        public_signal_count = wire_active_actors.public_signal_count + 1,
        expires_at = EXCLUDED.expires_at
      """,
      logger: logger
    )
  }

  private func isActiveActor(hash: String, asOf: Date) async throws -> Bool {
    let rows = try await pool.query(
      "SELECT EXISTS(SELECT 1 FROM wire_active_actors WHERE actor_key_hash = \(hash) AND expires_at > \(asOf))",
      logger: logger
    )
    for try await row in rows { return try row.decode(Bool.self) }
    return false
  }

  private func insertSignal(
    event: InboxEvent,
    canonicalKey: String,
    actorHash: String,
    sourceURI: String,
    kind: String,
    asOf: Date
  ) async throws {
    let eventKey = "\(event.environment):\(event.sourceGeneration):\(event.sequence)"
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "SELECT ensure_wire_signal_event_partition((\(event.eventTime) AT TIME ZONE 'UTC')::date)",
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO wire_signal_events
          (event_key, canonical_key, signal_kind, actor_key_hash, source_uri,
           occurred_at, expires_at)
        VALUES
          (\(eventKey), \(canonicalKey), \(kind), \(actorHash), \(sourceURI),
           \(event.eventTime), \(event.eventTime.addingTimeInterval(WireDataPolicy.signalRetention)))
        ON CONFLICT (occurred_at, event_key) DO NOTHING
        """,
        logger: logger
      )
    }
  }

  private func refreshRollups(asOf: Date) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "DELETE FROM wire_signal_rollups",
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO wire_signal_rollups
          (canonical_key, distinct_actors_1h, distinct_actors_24h, distinct_actors_7d,
           signals_1h, signals_24h, signals_7d, communities_24h,
           primary_community_key_hash, recommendations_24h,
           shares_1h, shares_24h, distinct_likers_24h, likes_1h, likes_24h,
           distinct_reposters_24h, reposts_1h, reposts_24h, updated_at)
        SELECT canonical_key,
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash),
          COUNT(*) FILTER (WHERE occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(*) FILTER (WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(*),
          COUNT(DISTINCT community_key_hash) FILTER (
            WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400)) AND community_key_hash IS NOT NULL),
          MODE() WITHIN GROUP (ORDER BY community_key_hash) FILTER (
            WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400)) AND community_key_hash IS NOT NULL),
          COUNT(*) FILTER (WHERE signal_kind = 'recommendation'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE signal_kind IN ('share','quote','recommendation','publication')
            AND occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE signal_kind IN ('share','quote','recommendation','publication')
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
            AND occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
            AND occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          \(asOf)
        FROM wire_signal_events
        WHERE occurred_at >= \(asOf.addingTimeInterval(-7 * 86_400)) AND expires_at > \(asOf)
        GROUP BY canonical_key
        """,
        logger: logger
      )
    }
  }

  private func pruneActiveGraph(asOf: Date) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        DELETE FROM wire_active_actors actor
        WHERE actor.expires_at <= \(asOf)
          OR actor.actor_key_hash IN (
            SELECT actor_key_hash FROM wire_active_actors
            WHERE expires_at > \(asOf)
            ORDER BY last_active_at DESC, actor_key_hash
            OFFSET \(WireDataPolicy.maximumActiveActors)
          )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_follow_edges edge
        WHERE edge.expires_at <= \(asOf)
          OR NOT EXISTS (
            SELECT 1 FROM wire_active_actors actor
            WHERE actor.actor_key_hash = edge.follower_key_hash)
          OR NOT EXISTS (
            SELECT 1 FROM wire_active_actors actor
            WHERE actor.actor_key_hash = edge.followee_key_hash)
        """,
        logger: logger
      )
    }
  }

  private func refreshCommunitiesIfNeeded(asOf: Date) async throws {
    let rows = try await pool.query(
      "SELECT MAX(assigned_at) FROM wire_actor_communities",
      logger: logger
    )
    var lastAssigned: Date?
    for try await row in rows { lastAssigned = try row.decode(Date?.self) }
    if let lastAssigned,
      asOf.timeIntervalSince(lastAssigned) < WireDataPolicy.clusteringCadence
    { return }

    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        CREATE TEMP TABLE wire_cluster_work (
          actor_key_hash TEXT PRIMARY KEY,
          label TEXT NOT NULL
        ) ON COMMIT DROP
        """,
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO wire_cluster_work (actor_key_hash, label)
        SELECT actor_key_hash, actor_key_hash
        FROM wire_active_actors
        WHERE expires_at > \(asOf)
        """,
        logger: logger
      )
      for _ in 0..<6 {
        try await connection.query(
          """
          UPDATE wire_cluster_work current
          SET label = LEAST(current.label, neighbor.minimum_label)
          FROM (
            SELECT actor_key_hash, MIN(label) AS minimum_label
            FROM (
              SELECT edge.follower_key_hash AS actor_key_hash, target.label
              FROM wire_follow_edges edge
              JOIN wire_cluster_work target ON target.actor_key_hash = edge.followee_key_hash
              UNION ALL
              SELECT edge.followee_key_hash AS actor_key_hash, source.label
              FROM wire_follow_edges edge
              JOIN wire_cluster_work source ON source.actor_key_hash = edge.follower_key_hash
            ) adjacent
            GROUP BY actor_key_hash
          ) neighbor
          WHERE current.actor_key_hash = neighbor.actor_key_hash
          """,
          logger: logger
        )
      }
      try await connection.query("DELETE FROM wire_actor_communities", logger: logger)
      try await connection.query(
        """
        INSERT INTO wire_actor_communities
          (actor_key_hash, community_key_hash, algorithm_version, assigned_at, expires_at)
        SELECT work.actor_key_hash, work.label, 'wire-community-v1', \(asOf),
               \(asOf.addingTimeInterval(WireDataPolicy.communityAssignmentRetention))
        FROM wire_cluster_work work
        JOIN (
          SELECT label FROM wire_cluster_work GROUP BY label HAVING COUNT(*) >= 3
        ) qualifying ON qualifying.label = work.label
        """,
        logger: logger
      )
      try await connection.query(
        """
        UPDATE wire_signal_events signal
        SET community_key_hash = community.community_key_hash
        FROM wire_actor_communities community
        WHERE community.actor_key_hash = signal.actor_key_hash
        """,
        logger: logger
      )
      try await connection.query(
        """
        UPDATE wire_signal_events signal
        SET community_key_hash = NULL
        WHERE NOT EXISTS (
          SELECT 1 FROM wire_actor_communities community
          WHERE community.actor_key_hash = signal.actor_key_hash)
        """,
        logger: logger
      )
    }
  }

  private func finish(
    _ event: InboxEvent,
    status: String,
    retryAt: Date,
    reason: String?,
    asOf: Date
  ) async throws {
    let appliedAt: Date? = status == "applied" ? asOf : nil
    let deadAt: Date? = status == "dead_letter" ? asOf : nil
    try await pool.query(
      """
      UPDATE wire_ingestion_inbox
      SET status = \(status), next_attempt_at = \(retryAt), failure_category = \(reason),
          failure_reason = \(reason), applied_at = \(appliedAt), dead_lettered_at = \(deadAt),
          lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL, updated_at = \(asOf)
      WHERE environment = \(event.environment) AND source_generation = \(event.sourceGeneration)
        AND seq = \(event.sequence) AND lease_token = \(event.leaseToken)
      """,
      logger: logger
    )
  }

  private static func firstString(_ value: Any, keys: [String]) -> String? {
    if let dictionary = value as? [String: Any] {
      for key in keys {
        if let string = dictionary[key] as? String, !string.isEmpty { return string }
        if let strings = dictionary[key] as? [String], let first = strings.first { return first }
      }
      for child in dictionary.values {
        if let result = firstString(child, keys: keys) { return result }
      }
    } else if let array = value as? [Any] {
      for child in array {
        if let result = firstString(child, keys: keys) { return result }
      }
    }
    return nil
  }

  private static func externalURL(_ record: [String: Any]) -> String? {
    let candidates = allStrings(record, keys: ["uri", "url"])
    return candidates.first { value in
      guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
      return (scheme == "http" || scheme == "https") && url.host != nil
    }
  }

  private static func allStrings(_ value: Any, keys: Set<String>) -> [String] {
    var result: [String] = []
    if let dictionary = value as? [String: Any] {
      for (key, child) in dictionary {
        if keys.contains(key), let string = child as? String { result.append(string) }
        result.append(contentsOf: allStrings(child, keys: keys))
      }
    } else if let array = value as? [Any] {
      for child in array { result.append(contentsOf: allStrings(child, keys: keys)) }
    }
    return result
  }

  private static func containsQuote(_ record: [String: Any]) -> Bool {
    guard let type = firstString(record["embed"] as Any, keys: ["$type"]) else { return false }
    return type.contains("record")
  }

  private static func primaryLanguage(_ raw: String?) -> String {
    guard let raw else { return "und" }
    let value = raw.lowercased().split(separator: "-").first.map(String.init) ?? "und"
    return value.count >= 2 && value.count <= 8 ? value : "und"
  }

  private static func date(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    return ISO8601DateFormatter().date(from: raw)
  }
}
