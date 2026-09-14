import Foundation
import Hummingbird
import HummingbirdTesting
import GatewayCore
import Logging
import PostgresNIO
import ThinAppViewCore
import Testing
@testable import AppView

@Suite("AppView feed error classification")
struct AppViewFeedErrorTests {
  @Test("request errors keep their status and are not retryable")
  func requestErrorClassification() {
    let error = AppViewFeedErrorClassifier.classify(
      HTTPError(.badRequest, message: "Invalid cursor"),
      requestId: "req-400"
    )
    #expect(error.status == .badRequest)
    #expect(error.code == "invalid_request")
    #expect(error.requestId == "req-400")
    #expect(error.retryable == false)
  }

  @Test("connection failures are transient and retryable")
  func transientClassification() {
    let error = AppViewFeedErrorClassifier.classify(
      StubConnectionPoolError(),
      requestId: "req-503"
    )
    #expect(error.status == .serviceUnavailable)
    #expect(error.code == "feed_dependency_unavailable")
    #expect(error.retryable)
  }

  @Test("bounded retry succeeds once and never loops")
  func boundedRetry() async throws {
    let attempts = AttemptCounter()
    let value: String = try await AppViewFeedExecution.run(requestId: "req-retry") {
      let attempt = await attempts.next()
      if attempt == 1 {
        throw StubConnectionPoolError()
      }
      return "ok"
    }
    #expect(value == "ok")
    #expect(await attempts.value == 2)
  }

  @Test("retry retains one monotonic deadline and success cancels its timer")
  func retryDeadline() async throws {
    let attempts = AttemptCounter()
    let instants = DeadlineRecorder()
    let started = ContinuousClock.now
    let _: String = try await AppViewFeedExecution.run(requestId: "req-budget") {
      await instants.append(try #require(AppViewFeedQueryDeadline.current).instant)
      if await attempts.next() == 1 { throw StubConnectionPoolError() }
      return "ok"
    }
    let recorded = await instants.values
    #expect(recorded.count == 2 && recorded[0] == recorded[1])
    #expect(started.duration(to: .now) < .seconds(1))
  }

  @Test("deadline failures are 504 and are never retried")
  func deadlineDoesNotRetry() async throws {
    let attempts = AttemptCounter()
    do {
      let _: String = try await AppViewFeedExecution.run(requestId: "req-timeout") {
        _ = await attempts.next()
        throw AppViewFeedQueryDeadline.Failure.exceeded
      }
      Issue.record("deadline failure succeeded")
    } catch {
      let classified = try #require(error as? AppViewFeedError)
      #expect(classified.status == .gatewayTimeout)
      #expect(classified.requestId == "req-timeout")
    }
    #expect(await attempts.value == 1)
  }

  @Test("typed PostgreSQL states preserve timeout, transient, and internal distinctions",
    .enabled(if: ProcessInfo.processInfo.environment["THIN_APPVIEW_TEST_DATABASE_URL"] != nil))
  func postgresStates() async throws {
    let url = try #require(ProcessInfo.processInfo.environment["THIN_APPVIEW_TEST_DATABASE_URL"])
    let logger = Logger(label: "appview-feed-error.tests")
    let pool = PostgresClient(configuration: try makePostgresConfig(from: url, logger: logger))
    let run = Task { await pool.run() }
    await Task.yield()
    do {
      for (state, status) in [("57014", 504), ("57P01", 503), ("53300", 503), ("08006", 503), ("23505", 500), ("XX000", 500)] {
        // Fixed test states only; deliberately sensitive server text must never reach the response.
        let sql = "DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '\(state)', MESSAGE = 'private viewer and SQL', TABLE = 'connection_private'; END $$;"
        do {
          for try await _ in try await pool.query(.init(unsafeSQL: sql), logger: logger) {}
          Issue.record("expected PostgreSQL error")
        } catch {
          #expect(error is PSQLError)
          let classified = AppViewFeedErrorClassifier.classify(error, requestId: "req-state")
          #expect(classified.status.code == status)
          #expect(!classified.message.contains("private"))
          #expect(classified.retryable == (status != 500))
        }
      }
    }
    run.cancel()
    await run.value
  }

  @Test("typed PostgreSQL transport codes without SQLSTATE remain allowlisted")
  func postgresTransportCodes() {
    for code: PSQLError.Code in [
      .connectionError, .serverClosedConnection, .clientClosedConnection, .poolClosed, .uncleanShutdown,
    ] {
      #expect(AppViewFeedErrorClassifier.postgresStatus(code: code, sqlState: nil) == .serviceUnavailable)
    }
    #expect(AppViewFeedErrorClassifier.postgresStatus(code: .queryCancelled, sqlState: nil) == .gatewayTimeout)
    for code: PSQLError.Code in [.server, .saslError, .messageDecodingFailure, .invalidCommandTag, .tooManyParameters] {
      #expect(AppViewFeedErrorClassifier.postgresStatus(code: code, sqlState: nil) == .internalServerError)
    }
    #expect(AppViewFeedErrorClassifier.postgresStatus(code: .connectionError, sqlState: "23505") == .internalServerError)
  }

  @Test("actual closed PostgreSQL connections classify as retryable with and without transaction wrapping",
    .enabled(if: ProcessInfo.processInfo.environment["THIN_APPVIEW_TEST_DATABASE_URL"] != nil),
    arguments: [false, true])
  func closedPostgresConnection(transactional: Bool) async throws {
    let url = try #require(ProcessInfo.processInfo.environment["THIN_APPVIEW_TEST_DATABASE_URL"])
    let logger = Logger(label: "appview-feed-closed-connection.tests")
    let pool = PostgresClient(configuration: try makePostgresConfig(from: url, logger: logger))
    let run = Task { await pool.run() }
    defer { run.cancel() }
    let transportError = try await pool.withConnection { connection in
      let pidRows = try await connection.query("SELECT pg_backend_pid()", logger: logger)
      var backendPID: Int32 = 0
      for try await row in pidRows { backendPID = try row.decode(Int32.self) }
      let query = Task {
        for try await _ in try await connection.query("SELECT pg_sleep(5)", logger: logger) {}
      }
      var queryStarted = false
      for _ in 0..<100 {
        let activity = try await pool.query(
          "SELECT wait_event FROM pg_stat_activity WHERE pid = \(backendPID) AND wait_event = 'PgSleep'",
          logger: logger)
        for try await _ in activity { queryStarted = true }
        if queryStarted { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      // Closing while work is in flight yields a real transport error. Submitting
      // new work after close hangs in this PostgresNIO version, so avoid that fixture.
      try await connection.close()
      do {
        try await query.value
        Issue.record("Closing the connection must fail its active query")
        throw HTTPError(.internalServerError)
      } catch let error as PSQLError {
        #expect(queryStarted)
        #expect(error.serverInfo?[.sqlState] == nil)
        return error
      }
    }
    var observedError: any Error = transportError
    if transactional {
      do {
        // A fresh transaction wraps the real failure without trying to roll back
        // on an already closed connection (which has the same driver limitation).
        try await pool.withTransaction(logger: logger) { _ in throw transportError }
      } catch {
        #expect(error is PostgresTransactionError)
        observedError = error
      }
    }
    let classified = AppViewFeedErrorClassifier.classify(observedError, requestId: "req-closed")
    #expect(classified.status == .serviceUnavailable)
    #expect(classified.code == "feed_dependency_unavailable")
    #expect(classified.retryable)
    #expect(classified.message == "The feed is temporarily unavailable.")
    // Pool replacement must remain usable after classifying the failed request.
    for try await row in try await pool.query("SELECT 1", logger: logger) {
      #expect(try row.decode(Int.self) == 1)
    }
  }

  @Test("feed failures record request timing without query or exception data")
  func safeFailureEvidence() async throws {
    let capture = AppViewFeedLogCapture()
    let router = Router(context: GatewayRequestContext.self)
    router.add(middleware: AppViewFeedErrorMiddleware())
    router.get("/v1/appview/feed") { _, _ -> Response in
      throw NSError(domain: "secret viewer did:plc:private SQL password", code: 1)
    }
    try await Application(router: router, logger: capture.logger()).test(.router) { client in
      let response = try await client.execute(uri: "/v1/appview/feed?viewer=did:plc:private&token=secret", method: .get)
      #expect(response.status == .internalServerError)
      let record = try #require(capture.records.first { $0["error_code"]?.description == "feed_internal_error" })
      #expect(record["route"]?.description == "/v1/appview/feed")
      #expect(record["status"]?.description == "500")
      #expect(Int(record["duration_ms"]?.description ?? "") != nil)
      let body = try JSONDecoder().decode(AppViewFeedErrorEnvelope.self, from: Data(response.body.readableBytesView))
      #expect(record["request_id"]?.description == body.requestId)
      #expect(!body.message.contains("secret"))
      let fields = record.description
      #expect(!fields.contains("did:plc:private") && !fields.contains("secret") && !fields.contains("password"))
    }
  }

  @Test("cursor and numeric validation fail before feed work")
  func requestValidation() {
    #expect(throws: AppViewFeedError.self) {
      _ = try ThinAppViewRoutes.validatedCursor("not-a-cursor", requestId: "req-cursor")
    }
    #expect(throws: AppViewFeedError.self) {
      _ = try ThinAppViewRoutes.validatedInteger(
        "0",
        name: "limit",
        defaultValue: 50,
        range: 1...100,
        requestId: "req-limit"
      )
    }
    #expect(throws: AppViewFeedError.self) {
      _ = try ThinAppViewRoutes.validatedOptionalInteger(
        "not-a-number",
        name: "maxEntries",
        range: 1...500,
        requestId: "req-max"
      )
    }
  }
}

private struct StubConnectionPoolError: Error {}

private actor AttemptCounter {
  private(set) var value = 0

  func next() -> Int {
    value += 1
    return value
  }
}

private actor DeadlineRecorder {
  private(set) var values: [ContinuousClock.Instant] = []
  func append(_ value: ContinuousClock.Instant) { values.append(value) }
}
