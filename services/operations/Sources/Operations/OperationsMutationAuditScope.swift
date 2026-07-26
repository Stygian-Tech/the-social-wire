import Foundation
import HTTPTypes
import Hummingbird
import OperationsCore

/// Request-local mutable context for one authenticated operator mutation attempt.
///
/// A scope is only accessed by its owning request task. `@unchecked Sendable` allows that
/// request-local reference to cross suspension points without pretending the fields are safe for
/// concurrent mutation.
final class OperationsMutationAuditScope: @unchecked Sendable {
  private let operatorDid: String
  private let requestId: String
  private var action: String
  private let targetType: String
  private let targetId: String?
  private var idempotencyKey: String?
  private var expectedVersion: Int?
  private var note: String?
  private var before: [String: String] = [:]

  init(
    operatorDid: String,
    requestId: String,
    action: String,
    targetType: String,
    targetId: String?,
    idempotencyKey: String? = nil
  ) {
    self.operatorDid = operatorDid
    self.requestId = requestId
    self.action = action
    self.targetType = targetType
    self.targetId = targetId
    self.idempotencyKey = idempotencyKey.map { String($0.prefix(128)) }
  }

  func update(
    action: String? = nil,
    idempotencyKey: String? = nil,
    expectedVersion: Int? = nil,
    note: String? = nil
  ) {
    if let action { self.action = action }
    if let idempotencyKey { self.idempotencyKey = String(idempotencyKey.prefix(128)) }
    self.expectedVersion = expectedVersion
    self.note = note.map { String($0.prefix(280)) }
  }

  func setBefore(_ before: [String: String]) {
    self.before = before
  }

  func failureAudit(
    error: Error,
    responseStatus: HTTPResponse.Status
  ) -> OperationsMutationAudit {
    OperationsMutationAudit(
      operatorDid: operatorDid,
      requestId: requestId,
      action: action,
      targetType: targetType,
      targetId: targetId,
      idempotencyKey: idempotencyKey,
      expectedVersion: expectedVersion,
      note: note,
      before: before,
      after: [
        "error": OperationsRedactor.errorCategory(error),
        "httpStatus": String(responseStatus.code),
      ],
      outcome: responseStatus.code < 500 ? "rejected" : "failed")
  }
}
