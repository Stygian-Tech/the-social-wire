import Foundation
import HTTPTypes
import Hummingbird
import Logging
import Testing

@testable import Operations
@testable import OperationsCore

@Test("validation and required-header rejections are durably audited without changing the response")
func mutationValidationRejectionIsDurablyAudited() async throws {
  let (store, cleanup) = try makeAuditStore()
  defer { cleanup() }
  let routes = OperationsRoutes(store: store, config: testOperationsConfiguration())
  let audit = OperationsMutationAuditScope(
    operatorDid: "did:plc:operator", requestId: "request-validation",
    action: "gap.confirmed", targetType: "gap", targetId: "gap-1",
    idempotencyKey: "validation-1")
  audit.update(idempotencyKey: "validation-1", expectedVersion: 4, note: nil)
  audit.setBefore(["status": "suspected", "version": "4"])

  do {
    _ = try await routes.auditedMutation(audit) {
      try OperationsRoutes.validateIdempotencyHeader(
        headerValue: nil, bodyKey: "validation-1")
      return "unreachable"
    }
    Issue.record("Expected the missing idempotency header to be rejected")
  } catch let error as HTTPError {
    #expect(error.status == .badRequest)
    #expect(error.body == "Idempotency-Key header is required")
    #expect(error.headers.isEmpty)
  }

  let records = try await store.mutationAudits(idempotencyKey: "validation-1")
  #expect(records.count == 1)
  #expect(records.first?.requestId == "request-validation")
  #expect(records.first?.expectedVersion == 4)
  #expect(records.first?.before["status"] == "suspected")
  #expect(records.first?.before["version"] == "4")
  #expect(records.first?.before["expectedVersion"] == "4")
  #expect(records.first?.after["httpStatus"] == "400")
  #expect(records.first?.outcome == "rejected")

  let mismatchAudit = OperationsMutationAuditScope(
    operatorDid: "did:plc:operator", requestId: "request-mismatch",
    action: "gap.confirmed", targetType: "gap", targetId: "gap-1",
    idempotencyKey: "validation-2")
  mismatchAudit.update(idempotencyKey: "validation-2", expectedVersion: 4, note: nil)
  do {
    _ = try await routes.auditedMutation(mismatchAudit) {
      try OperationsRoutes.validateIdempotencyHeader(
        headerValue: "different-key", bodyKey: "validation-2")
      return "unreachable"
    }
    Issue.record("Expected the mismatched idempotency header to be rejected")
  } catch let error as HTTPError {
    #expect(error.status == .badRequest)
    #expect(error.body == "Idempotency-Key header does not match the request body")
  }
  let mismatchRecords = try await store.mutationAudits(idempotencyKey: "validation-2")
  #expect(mismatchRecords.count == 1)
  #expect(mismatchRecords.first?.outcome == "rejected")
}

@Test("conflicts are durably audited and preserve exact HTTP status, headers, and body")
func mutationConflictPreservesHTTPError() async throws {
  let (store, cleanup) = try makeAuditStore()
  defer { cleanup() }
  let routes = OperationsRoutes(store: store, config: testOperationsConfiguration())
  let audit = OperationsMutationAuditScope(
    operatorDid: "did:plc:operator", requestId: "request-conflict",
    action: "backfill.pause", targetType: "backfill", targetId: "job-1",
    idempotencyKey: "conflict-1")
  audit.update(idempotencyKey: "conflict-1", expectedVersion: 9, note: "optional note")
  audit.setBefore(["status": "running", "version": "10"])
  var headers = HTTPFields()
  headers[HTTPField.Name("Retry-After")!] = "7"
  let conflict = HTTPError(.conflict, headers: headers, message: "refresh first")

  do {
    _ = try await routes.auditedMutation(audit) { () async throws -> String in
      throw conflict
    }
    Issue.record("Expected the conflict to be rethrown")
  } catch let error as HTTPError {
    #expect(error.status == .conflict)
    #expect(error.body == "refresh first")
    #expect(error.headers[HTTPField.Name("Retry-After")!] == "7")
  }

  let records = try await store.mutationAudits(idempotencyKey: "conflict-1")
  #expect(records.count == 1)
  #expect(records.first?.after["httpStatus"] == "409")
  #expect(records.first?.outcome == "rejected")
}

@Test("malformed mutation bodies are durably audited as validation rejections")
func malformedMutationBodyIsDurablyAudited() async throws {
  let (store, cleanup) = try makeAuditStore()
  defer { cleanup() }
  let routes = OperationsRoutes(store: store, config: testOperationsConfiguration())
  let audit = OperationsMutationAuditScope(
    operatorDid: "did:plc:operator", requestId: "request-malformed",
    action: "alert.acknowledge", targetType: "alert", targetId: "alert-1",
    idempotencyKey: "malformed-1")

  do {
    _ = try await routes.auditedMutation(audit) { () async throws -> String in
      // Hummingbird's Request.decode maps malformed JSON and missing coding keys to this
      // bad-request boundary before the route can hydrate the body-derived audit fields.
      throw HTTPError(.badRequest, message: "Coding key `expectedVersion` not found.")
    }
    Issue.record("Expected the malformed body to be rejected")
  } catch let error as HTTPError {
    #expect(error.status == .badRequest)
    #expect(error.body == "Coding key `expectedVersion` not found.")
  }

  let records = try await store.mutationAudits(idempotencyKey: "malformed-1")
  #expect(records.count == 1)
  #expect(records.first?.requestId == "request-malformed")
  #expect(records.first?.after["httpStatus"] == "400")
  #expect(records.first?.outcome == "rejected")
}

@Test("optimistic version conflicts are mapped and durably audited")
func mutationVersionConflictIsDurablyAudited() async throws {
  let (store, cleanup) = try makeAuditStore()
  defer { cleanup() }
  let routes = OperationsRoutes(store: store, config: testOperationsConfiguration())
  let audit = OperationsMutationAuditScope(
    operatorDid: "did:plc:operator", requestId: "request-version-conflict",
    action: "gap.confirmed", targetType: "gap", targetId: "gap-1",
    idempotencyKey: "version-conflict-1")
  audit.update(idempotencyKey: "version-conflict-1", expectedVersion: 3, note: nil)
  audit.setBefore(["status": "confirmed", "version": "4"])

  do {
    _ = try await routes.auditedMutation(audit) { () async throws -> String in
      throw OperationsStoreError.versionConflict(expected: 3, actual: 4)
    }
    Issue.record("Expected the stale expected version to conflict")
  } catch let error as HTTPError {
    #expect(error.status == .conflict)
    #expect(error.body == "Operational state changed; refresh and retry")
  }

  let records = try await store.mutationAudits(idempotencyKey: "version-conflict-1")
  #expect(records.count == 1)
  #expect(records.first?.expectedVersion == 3)
  #expect(records.first?.before["version"] == "4")
  #expect(records.first?.after["httpStatus"] == "409")
  #expect(records.first?.outcome == "rejected")
}

@Test("store failures are durably classified as failed mutation attempts")
func mutationStoreFailureIsDurablyAudited() async throws {
  let (store, cleanup) = try makeAuditStore()
  defer { cleanup() }
  let routes = OperationsRoutes(store: store, config: testOperationsConfiguration())
  let audit = OperationsMutationAuditScope(
    operatorDid: "did:plc:operator", requestId: "request-store-failure",
    action: "alert.resolve", targetType: "alert", targetId: "alert-1",
    idempotencyKey: "store-failure-1")

  do {
    _ = try await routes.auditedMutation(audit) { () async throws -> String in
      throw OperationsStoreError.missingCreatedRecord
    }
    Issue.record("Expected the persistence failure to be rethrown")
  } catch let error as HTTPError {
    #expect(error.status == .internalServerError)
    #expect(error.body == "Operations persistence failed")
  }

  let records = try await store.mutationAudits(idempotencyKey: "store-failure-1")
  #expect(records.count == 1)
  #expect(records.first?.after["httpStatus"] == "500")
  #expect(records.first?.outcome == "failed")
}

@Test("audit-store failure is never swallowed")
func mutationAuditStoreFailureBecomesExplicitFailure() async throws {
  let (store, cleanup) = try makeAuditStore()
  defer { cleanup() }
  let probe = MutationAuditRecorderProbe()
  let routes = OperationsRoutes(
    store: store,
    config: testOperationsConfiguration(),
    auditRecorder: { audit in
      await probe.record(audit)
      throw OperationsStoreError.missingCreatedRecord
    })
  let audit = OperationsMutationAuditScope(
    operatorDid: "did:plc:operator", requestId: "request-audit-failure",
    action: "gap.confirmed", targetType: "gap", targetId: "gap-1",
    idempotencyKey: "audit-failure-1")

  do {
    _ = try await routes.auditedMutation(audit) { () async throws -> String in
      throw HTTPError(.conflict, message: "state changed")
    }
    Issue.record("Expected the audit persistence failure to be surfaced")
  } catch let error as HTTPError {
    #expect(error.status == .internalServerError)
    #expect(error.body == "The mutation outcome could not be durably audited")
  }
  #expect(await probe.count() == 1)
}

@Test("service and ingestion changes fit the five-second live visibility budget")
func liveEvidenceVisibilityBudgetIsBounded() {
  let worstCaseSeconds =
    OperationsEvidenceChangeMonitor.defaultPollIntervalSeconds
    + OperationsRoutes.eventStreamPollIntervalSeconds
    + OperationsRoutes.liveRefetchAllowanceSeconds

  #expect(worstCaseSeconds <= OperationsRoutes.liveVisibilityBudgetSeconds)
  #expect(OperationsEvidenceChangeMonitor.defaultPollIntervalSeconds <= 2)
  #expect(OperationsRoutes.eventStreamPollIntervalSeconds <= 1)
  #expect(
    Double(OperationsCapabilityResolver.fallbackPollMilliseconds) / 1_000
      + OperationsRoutes.liveRefetchAllowanceSeconds
      <= OperationsRoutes.liveVisibilityBudgetSeconds)
}

private func makeAuditStore() throws -> (SQLiteOperationsStore, () -> Void) {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("operations-route-audit-\(UUID().uuidString).sqlite")
  let store = try SQLiteOperationsStore(
    path: url.path, environment: "dev", logger: Logger(label: "operations.audit.test"))
  return (store, { try? FileManager.default.removeItem(at: url) })
}

private func testOperationsConfiguration() -> OperationsConfiguration {
  OperationsConfiguration.fromEnvironment([
    "APP_ENV": "dev",
    "OPERATIONS_BACKFILL_FINGERPRINT_SECRET": "audit-test-secret",
  ])
}
