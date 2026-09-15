import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("malformed publication rollback preserves FIFO and terminal lease fencing",
    arguments: ["terminal", "lease-replaced", "cancelled"])
  func malformedPublicationTransactionFIFO(action: String) async throws {
    try await WireSourceVersionFixture.run(collection: "site.standard.publication") { fixture in
      let base = fixture.base
      let now = base.now.addingTimeInterval(60)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision)
      // Valid transport and record shape; only the publication metadata is malformed.
      try await base.pool.query("""
        UPDATE wire_ingestion_inbox SET payload = payload #- '{commit,record,url}'
        WHERE environment = \(base.environment) AND seq = 1
        """, logger: base.logger)
      let document = WireSourceVersionFixture(base: base)
      try await document.insert(sequence: 2, revision: WireSourceVersionFixture.newerRevision)
      let head = try await fixture.claim(sequence: 1)
      let gate = WirePublicationRollbackGate()
      let processor = try PostgresWireInboxProcessor(
        pool: base.pool, logger: base.logger, actorSecret: String(repeating: "s", count: 32),
        publicationResolver: gate, sourceScope: base.scope)
      let applying = Task { try await processor.applyClaimed(head, asOf: now) }
      do {
        for await _ in gate.rolledBack { break }
        #expect(try await processor.claimNext(in: head.repository, asOf: now) == nil)
        #expect(try await base.scalar("""
          SELECT COUNT(*)::bigint FROM wire_ingestion_inbox
          WHERE environment = \(base.environment) AND seq = 1 AND status = 'leased'
            AND attempt_count = 1 AND dead_lettered_at IS NULL
          """) == 1)
        #expect(try await base.scalar("""
          SELECT COUNT(*)::bigint FROM wire_standard_record_fences
          WHERE environment = \(base.environment)
          """) == 0)
        #expect(try await fixture.projectionExists() == false)
        if action == "lease-replaced" {
          try await base.pool.query("""
            UPDATE wire_ingestion_inbox SET lease_token = 'replacement-token'
            WHERE environment = \(base.environment) AND seq = 1
            """, logger: base.logger)
        } else if action == "cancelled" { applying.cancel() }
        await gate.release()
        if action == "cancelled" {
          do {
            _ = try await applying.value
            Issue.record("Cancellation must not terminalize or retry the row")
          } catch is CancellationError {}
        } else {
          #expect(try await applying.value == (action == "terminal" ? .terminal : .leaseLost))
        }
        if action == "terminal" {
          #expect(try await base.scalar("""
            SELECT COUNT(*)::bigint FROM wire_ingestion_inbox
            WHERE environment = \(base.environment) AND seq = 1 AND status = 'dead_letter'
              AND attempt_count = 1 AND failure_category = 'malformed_event'
              AND failure_reason = 'malformed_event' AND dead_lettered_at IS NOT NULL
              AND lease_token IS NULL AND payload #>> '{commit,record,$type}' = 'site.standard.publication'
            """) == 1)
          let follower = try #require(try await processor.claimNext(in: head.repository, asOf: now))
          #expect(follower.sequence == 2)
          #expect(try await base.processor().applyClaimed(follower, asOf: now) == .applied)
          try await fixture.insert(sequence: 3, revision: WireSourceVersionFixture.newerRevision)
          #expect(try await fixture.apply(sequence: 3) == .applied)
          #expect(try await fixture.projectionExists())
          try await fixture.insert(sequence: 4, revision: "3m22222222227", operation: "delete")
          #expect(try await fixture.apply(sequence: 4) == .applied)
          #expect(try await fixture.projectionExists() == false)
        } else {
          #expect(try await processor.claimNext(in: head.repository, asOf: now) == nil)
          #expect(try await base.scalar("""
            SELECT COUNT(*)::bigint FROM wire_ingestion_inbox
            WHERE environment = \(base.environment) AND seq = 1 AND status = 'leased'
              AND failure_category IS NULL AND dead_lettered_at IS NULL
            """) == 1)
        }
      } catch {
        applying.cancel()
        await gate.release()
        _ = await applying.result
        throw error
      }
    }
  }

  @Test("only a successful rollback unwraps known publication application errors",
    arguments: ["clean", "begin", "rollback", "commit", "unknown", "cancellation"])
  func malformedPublicationTransactionClassification(failure: String) async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      var transaction: PostgresTransactionError
      do {
        let _: Void = try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
          try await connection.query("SELECT 1", logger: fixture.logger)
          if failure == "cancellation" { throw CancellationError() }
          throw PostgresWireInboxProcessor.ApplyError.malformed
        }
        Issue.record("Expected a real transaction closure failure")
        return
      } catch let error as PostgresTransactionError { transaction = error }
      #expect(transaction.beginError == nil && transaction.rollbackError == nil && transaction.commitError == nil)
      let uncertain = NSError(domain: "tsw122.synthetic-transaction-failure", code: 1)
      switch failure {
      case "begin": transaction.beginError = uncertain
      case "rollback": transaction.rollbackError = uncertain
      case "commit": transaction.commitError = uncertain
      case "unknown": transaction.closureError = uncertain
      case "cancellation": transaction.closureError = CancellationError()
      default: break
      }
      let classified = PostgresWireInboxProcessor.applicationErrorAfterRollback(transaction)
      switch failure {
      case "clean": #expect(classified is PostgresWireInboxProcessor.ApplyError)
      case "cancellation": #expect(classified is CancellationError)
      default:
        let retained = try #require(classified as? PostgresTransactionError)
        #expect((retained.beginError != nil) == (failure == "begin"))
        #expect((retained.rollbackError != nil) == (failure == "rollback"))
        #expect((retained.commitError != nil) == (failure == "commit"))
      }
    }
  }

  @Test("publication database failures retry without releasing the FIFO follower",
    arguments: ["statement", "commit"])
  func malformedPublicationDatabaseFailureRetries(stage: String) async throws {
    try await WireSourceVersionFixture.run(collection: "site.standard.publication") { fixture in
      let base = fixture.base
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        title: "TSW122 Database Failure Fixture")
      try await WireSourceVersionFixture(base: base).insert(
        sequence: 2, revision: WireSourceVersionFixture.newerRevision)
      try await base.pool.query("""
        CREATE FUNCTION wire_malformed_transaction_test_fail() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.name = 'TSW122 Database Failure Fixture' THEN
            RAISE EXCEPTION 'synthetic publication transaction failure' USING ERRCODE = '40001';
          END IF;
          RETURN NEW;
        END $$
        """, logger: base.logger)
      do {
        let trigger: PostgresQuery = stage == "commit" ? """
          CREATE CONSTRAINT TRIGGER wire_malformed_transaction_test_fail
          AFTER INSERT ON wire_publications DEFERRABLE INITIALLY DEFERRED
          FOR EACH ROW EXECUTE FUNCTION wire_malformed_transaction_test_fail()
          """ : """
          CREATE TRIGGER wire_malformed_transaction_test_fail
          BEFORE INSERT ON wire_publications
          FOR EACH ROW EXECUTE FUNCTION wire_malformed_transaction_test_fail()
          """
        try await base.pool.query(trigger, logger: base.logger)
        let head = try await fixture.claim(sequence: 1)
        let processor = try base.processor()
        #expect(try await processor.applyClaimed(head, asOf: base.now.addingTimeInterval(60)) == .retry)
        #expect(try await fixture.projectionExists() == false)
        #expect(try await processor.claimNext(in: head.repository, asOf: base.now.addingTimeInterval(61)) == nil)
        #expect(try await base.scalar("""
          SELECT COUNT(*)::bigint FROM wire_ingestion_inbox
          WHERE environment = \(base.environment) AND seq = 1 AND status = 'retry'
            AND attempt_count = 1 AND failure_category LIKE '%PostgresTransactionError%'
            AND failure_category <> 'malformed_event' AND dead_lettered_at IS NULL
          """) == 1)
        try await base.pool.query(
          "DROP FUNCTION wire_malformed_transaction_test_fail() CASCADE", logger: base.logger)
        let retryAt = base.now.addingTimeInterval(121)
        let retry = try #require(try await processor.claimNext(in: head.repository, asOf: retryAt))
        #expect(retry.sequence == 1)
        #expect(try await processor.applyClaimed(retry, asOf: retryAt) == .applied)
        #expect(try await processor.claimNext(in: head.repository, asOf: retryAt)?.sequence == 2)
      } catch {
        _ = try? await base.pool.query(
          "DROP FUNCTION IF EXISTS wire_malformed_transaction_test_fail() CASCADE", logger: base.logger)
        throw error
      }
    }
  }

  @Test("real PostgreSQL statement failure stays a transaction failure after rollback")
  func malformedPublicationDatabaseFailureClassification() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      do {
        let _: Void = try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
          try await connection.query("SELECT 1 / 0", logger: fixture.logger)
        }
        Issue.record("Expected PostgreSQL division-by-zero failure")
      } catch let error as PostgresTransactionError {
        let retained = try #require(
          PostgresWireInboxProcessor.applicationErrorAfterRollback(error) as? PostgresTransactionError)
        #expect(retained.rollbackError == nil)
        let postgres = try #require(retained.closureError as? PSQLError)
        #expect(postgres.serverInfo?[.sqlState] == "22012")
      }
    }
  }
}
