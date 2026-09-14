import Foundation
import Logging
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test(
    "cancellation before domain-error acknowledgment preserves the recoverable lease",
    arguments: [WirePublicationQueryError.dnsUnavailable, .invalidResponse]
  )
  func cancelledDomainErrorLeavesInboxLeased(error: WirePublicationQueryError) async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-inbox-cancellation.integration")
    let configuration = try PostgresWireConfig.make(from: url, maximumConnections: 4, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }
    let environment = "wire-cancellation-\(UUID().uuidString.lowercased())"
    let now = Date()
    let repository = WireInboxRepository(
      environment: environment, sourceGeneration: "live", repoDID: "did:example:cancelled")
    let processor = try PostgresWireInboxProcessor(
      pool: pool, logger: logger, actorSecret: String(repeating: "s", count: 32),
      publicationResolver: CancellingInboxPublicationResolver(error: error),
      sourceScope: WireInboxSourceScope(environment: environment, sourceGenerations: ["live"]))
    let payload = """
      {"commit":{"record":{"site":"at://did:example:cancelled/site.standard.publication/main","path":"/article"}}}
      """
    do {
      try await pool.query(
        """
        INSERT INTO wire_ingestion_inbox
          (environment, source_generation, seq, source_host, cursor_kind, event_kind,
           repo_did, collection, operation, record_key, payload, event_time, next_attempt_at)
        VALUES
          (\(environment), 'live', 1, 'test', 'jetstream_v2_seq', 'commit', \(repository.repoDID),
           'site.standard.document', 'create', 'article', \(payload)::jsonb, \(now), \(now)),
          (\(environment), 'live', 2, 'test', 'jetstream_v2_seq', 'identity', \(repository.repoDID),
           NULL, NULL, NULL, '{}'::jsonb, \(now), \(now))
        """, logger: logger)
      let event = try #require(try await processor.claimNext(in: repository, asOf: now))
      let beforeRows = try await pool.query(
        """
        SELECT xmin::text || ':' || ctid::text FROM wire_ingestion_inbox
        WHERE environment = \(environment) AND source_generation = 'live' AND seq = 1
        """, logger: logger)
      var beforeTuple: String?
      for try await row in beforeRows { beforeTuple = try row.decode(String.self) }
      #expect(beforeTuple != nil)

      // The resolver cancels this child and then reports a domain error, as an in-flight
      // transport can do during shutdown. Neither typed error handler may acknowledge it.
      let applying = Task { try await processor.applyClaimed(event, asOf: now) }
      await #expect(throws: CancellationError.self) { try await applying.value }

      let afterRows = try await pool.query(
        """
        SELECT status, lease_token, xmin::text || ':' || ctid::text
        FROM wire_ingestion_inbox
        WHERE environment = \(environment) AND source_generation = 'live' AND seq = 1
        """, logger: logger)
      var observed = false
      for try await row in afterRows {
        let state = try row.decode((String, String?, String).self)
        #expect(state.0 == "leased")
        #expect(state.1 == event.leaseToken)
        #expect(state.2 == beforeTuple)
        observed = true
      }
      #expect(observed)
      #expect(try await processor.claimNext(in: repository, asOf: now) == nil)
      let recovered = try #require(
        try await processor.claimNext(in: repository, asOf: now.addingTimeInterval(121)))
      #expect(recovered.sequence == event.sequence)
      #expect(recovered.leaseToken != event.leaseToken)
    } catch {
      _ = try? await pool.query(
        "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
      throw error
    }
    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
  }
}

private struct CancellingInboxPublicationResolver: WirePublicationResolving {
  let error: WirePublicationQueryError

  func observe(_ metadata: WirePublicationMetadata, asOf: Date) async throws {}
  func remove(publicationURI: String, observedAt: Date) async throws {}

  func resolve(publicationURI: String, asOf: Date) async throws -> WirePublicationMetadata? {
    withUnsafeCurrentTask { $0?.cancel() }
    throw error
  }
}
