import Foundation
import Logging
import PostgresNIO

/// Compact logged record versions protect snapshot hydration from newer live
/// changes after the unlogged inbox has expired or restarted.
struct PostgresWireStandardRecordFence: Sendable {
  enum Order { case older, same, newer, conflict }

  let generation: String
  let sequence: Int64
  let host: String
  let cursor: String
  let kind: String
  let operation: String
  let revision: String?
  private(set) var observedRevision: String?
  let cid: String?
  let time: Date
  let activityRecorded: Bool

  init(event: WireInboxEvent, revision: String?, cid: String?, activityRecorded: Bool = false) {
    self.generation = event.sourceGeneration
    self.sequence = event.sequence
    self.host = event.sourceHost
    self.cursor = event.cursorKind
    self.kind = event.eventKind
    self.operation = event.operation ?? "update"
    self.revision = revision
    self.observedRevision = event.eventKind == "snapshot" ? revision : nil
    self.cid = cid
    self.time = event.eventTime
    self.activityRecorded = activityRecorded
  }

  private init(_ value: (String, Int64, String, String, String, String, String?, String?, Date, Bool, String?)) {
    generation = value.0
    sequence = value.1
    host = value.2
    cursor = value.3
    kind = value.4
    operation = value.5
    revision = value.6
    cid = value.7
    time = value.8
    activityRecorded = value.9
    observedRevision = value.10
  }

  static func load(event: WireInboxEvent, on connection: PostgresConnection, logger: Logger)
    async throws -> Self?
  {
    let rows = try await connection.query(
      """
      SELECT source_generation, seq, source_host, cursor_kind, event_kind, operation,
             repo_rev, record_cid, event_time, activity_recorded, observed_repo_rev
      FROM wire_standard_record_fences
      WHERE environment = \(event.environment) AND source_uri = \(event.sourceURI)
      """, logger: logger)
    for try await row in rows {
      return Self(try row.decode((String, Int64, String, String, String, String, String?, String?, Date, Bool, String?).self))
    }
    return nil
  }

  func compared(to current: Self) -> Order {
    let sameTransport = kind == "commit" && current.kind == "commit"
      && host == current.host && cursor == current.cursor && sequence == current.sequence
    let sameValue = (operation == "delete") == (current.operation == "delete")
      && (operation == "delete" || (cid != nil && cid == current.cid)
        || (sameTransport && cid == nil && current.cid == nil && operation == current.operation))
    let knownRevision = [current.revision, current.observedRevision].compactMap { $0 }
      .filter(Self.validRevision).max()
    if let revision, let previous = knownRevision, Self.validRevision(revision) {
      // A snapshot observes the whole repository revision, not the document's
      // original commit revision. Preserve identical content's real activity
      // anchor while retaining the snapshot watermark for later delete ordering.
      if sameValue, cid != nil,
        kind == "snapshot" || ((current.kind == "snapshot" || current.observedRevision != nil) && revision <= previous)
      { return .same }
      if revision != previous { return revision > previous ? .newer : .older }
      return sameValue ? .same : .conflict
    }
    // Independent snapshot observations and generations are never sequence clocks.
    if kind == "commit", current.kind == "commit", current.observedRevision == nil,
      host == current.host, cursor == current.cursor
    {
      if sequence != current.sequence { return sequence > current.sequence ? .newer : .older }
      return sameValue && revision == current.revision ? .same : .conflict
    }
    return .conflict
  }

  func observing(_ revision: String?) -> Self {
    var result = self
    result.observedRevision = [observedRevision, revision].compactMap { $0 }
      .filter(Self.validRevision).max()
    return result
  }

  static func validRevision(_ value: String) -> Bool {
    value.utf8.count == 13 && value.utf8.allSatisfy { "234567abcdefghijklmnopqrstuvwxyz".utf8.contains($0) }
  }

  func save(event: WireInboxEvent, on connection: PostgresConnection, asOf: Date, logger: Logger) async throws {
    try await connection.query(
      """
      INSERT INTO wire_standard_record_fences
        (environment, source_uri, source_generation, seq, source_host, cursor_kind, event_kind,
         operation, repo_rev, observed_repo_rev, record_cid, event_time, activity_recorded, updated_at)
      VALUES (\(event.environment), \(event.sourceURI), \(generation), \(sequence), \(host), \(cursor),
              \(kind), \(operation), \(revision), \(observedRevision), \(cid), \(time), \(activityRecorded), \(asOf))
      ON CONFLICT (environment, source_uri) DO UPDATE SET
        source_generation = EXCLUDED.source_generation, seq = EXCLUDED.seq,
        source_host = EXCLUDED.source_host, cursor_kind = EXCLUDED.cursor_kind,
        event_kind = EXCLUDED.event_kind, operation = EXCLUDED.operation,
        repo_rev = EXCLUDED.repo_rev, observed_repo_rev = EXCLUDED.observed_repo_rev, record_cid = EXCLUDED.record_cid,
        event_time = EXCLUDED.event_time, activity_recorded = EXCLUDED.activity_recorded,
        updated_at = EXCLUDED.updated_at
      WHERE (wire_standard_record_fences.source_generation, wire_standard_record_fences.seq,
             wire_standard_record_fences.repo_rev, wire_standard_record_fences.observed_repo_rev,
             wire_standard_record_fences.activity_recorded)
        IS DISTINCT FROM (EXCLUDED.source_generation, EXCLUDED.seq, EXCLUDED.repo_rev,
                          EXCLUDED.observed_repo_rev, EXCLUDED.activity_recorded)
      """, logger: logger)
  }

  func originalEvent(using claim: WireInboxEvent) -> WireInboxEvent {
    WireInboxEvent(environment: claim.environment, sourceGeneration: generation, sequence: sequence,
      sourceHost: host, cursorKind: cursor, eventKind: kind, repoDID: claim.repoDID,
      collection: claim.collection, operation: operation, recordKey: claim.recordKey,
      payloadJSON: claim.payloadJSON, eventTime: time, leaseToken: claim.leaseToken,
      attemptCount: claim.attemptCount)
  }
}
