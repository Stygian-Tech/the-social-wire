import Foundation
import PostgresNIO

@testable import WireWorkerCore

struct WirePublicationRecoveryFixture: Sendable {
  let source: WireSourceVersionFixture
  var base: WireRecommendationJournalFixture { source.base }
  var epoch: Date { base.now.addingTimeInterval(120) }
  var recovery: PostgresWirePublicationSignalRecovery {
    get throws {
      try .init(pool: base.pool, logger: base.logger, actorSecret: String(repeating: "s", count: 32),
        scope: .init(environment: base.environment, sourceGenerations: ["live"]))
    }
  }

  func register(maximumSequence: Int64 = 100) async throws {
    try await base.pool.query(
      """
      INSERT INTO appview_jetstream_checkpoints
        (environment,source_generation,source_host,stream_nsid,filter_fingerprint,cursor_kind,
         last_staged_seq,replay_state,replay_after_seq,replay_sealed_seq)
      VALUES (\(base.environment),'live','jetstream.example.test','network.bsky.jetstream.subscribeEvents',
        \(base.environment),'jetstream_v2_seq',0,'replaying',0,\(maximumSequence))
      """, logger: base.logger)
    try await base.pool.query(
      """
      INSERT INTO wire_ingestion_inbox_epochs(environment,source_generation,initialized_at)
      VALUES (\(base.environment),'live',\(epoch))
      """, logger: base.logger)
    try await base.pool.query(
      """
      INSERT INTO wire_publication_signal_recovery_jobs
        (environment,source_generation,inbox_initialized_at,maximum_source_seq)
      VALUES (\(base.environment),'live',\(epoch),\(maximumSequence))
      """, logger: base.logger)
  }

  func loseSignal() async throws {
    try await base.pool.query(
      "DELETE FROM wire_signal_events WHERE source_uri = \(source.sourceURI)", logger: base.logger)
  }

  static func run(_ operation: (Self) async throws -> Void) async throws {
    try await WireSourceVersionFixture.run { source in
      let fixture = Self(source: source)
      do {
        try await operation(fixture)
        try await fixture.clean()
      } catch {
        try? await fixture.clean()
        throw error
      }
    }
  }

  private func clean() async throws {
    try await base.pool.query("DELETE FROM wire_publication_signal_recovery_jobs WHERE environment = \(base.environment)", logger: base.logger)
    try await base.pool.query("DELETE FROM wire_ingestion_inbox_epochs WHERE environment = \(base.environment)", logger: base.logger)
    try await base.pool.query("DELETE FROM appview_jetstream_checkpoints WHERE environment = \(base.environment)", logger: base.logger)
  }
}
