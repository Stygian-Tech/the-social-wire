import Foundation
import HTTPTypes
import Hummingbird
import OperationsCore
import PostgresNIO
import ThinAppViewCore

struct AppViewFeedErrorEnvelope: Codable, Sendable {
  let error: String
  let message: String
  let requestId: String
  let retryable: Bool
}

struct AppViewFeedError: HTTPResponseError {
  let status: HTTPResponse.Status
  let code: String
  let message: String
  let requestId: String
  let retryable: Bool

  func response(
    from request: Request,
    context: some RequestContext
  ) throws -> Response {
    let envelope = AppViewFeedErrorEnvelope(
      error: code,
      message: message,
      requestId: requestId,
      retryable: retryable
    )
    let data = try JSONEncoder().encode(envelope)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let requestIdHeader = HTTPField.Name("X-Request-ID") {
      headers[requestIdHeader] = requestId
    }
    return Response(status: status, headers: headers, body: .init(byteBuffer: .init(data: data)))
  }
}

enum AppViewFeedErrorClassifier {
  static func classify(_ error: any Error, requestId: String) -> AppViewFeedError {
    if let feedError = error as? AppViewFeedError {
      return feedError
    }
    if error is AppViewFeedQueryDeadline.Failure {
      return postgresFailure(status: .gatewayTimeout, requestId: requestId)
    }
    if let postgres = error as? PostgresError, case .connectionClosed = postgres {
      return postgresFailure(status: .serviceUnavailable, requestId: requestId)
    }
    if let postgres = postgresError(error) {
      return postgresFailure(
        status: postgresStatus(code: postgres.code, sqlState: postgres.serverInfo?[.sqlState]),
        requestId: requestId)
    }
    if error is CancellationError {
      return AppViewFeedError(
        status: .gatewayTimeout,
        code: "request_cancelled",
        message: "The feed request was cancelled.",
        requestId: requestId,
        retryable: true
      )
    }
    if let httpError = error as? HTTPError {
      let status = httpError.status
      return AppViewFeedError(
        status: status,
        code: code(for: status),
        message: status == .internalServerError
          ? "The feed could not be loaded."
          : String(describing: httpError),
        requestId: requestId,
        retryable: status == .serviceUnavailable || status == .gatewayTimeout
      )
    }
    if let responseError = error as? any HTTPResponseError {
      let status = responseError.status
      return AppViewFeedError(
        status: status,
        code: code(for: status),
        message: status.code >= 500 ? "The feed could not be loaded." : "The request was rejected.",
        requestId: requestId,
        retryable: status == .serviceUnavailable || status == .gatewayTimeout
      )
    }
    let category = OperationsRedactor.errorCategory(error).lowercased()
    let transientTokens = [
      "connection", "pool", "timeout", "timedout", "temporar", "unavailable",
      "closed", "reset", "brokenpipe", "toomanyconnections",
    ]
    let transient = transientTokens.contains { category.contains($0) }
    return AppViewFeedError(
      status: transient ? .serviceUnavailable : .internalServerError,
      code: transient ? "feed_dependency_unavailable" : "feed_internal_error",
      message: transient
        ? "The feed is temporarily unavailable."
        : "The feed could not be loaded.",
      requestId: requestId,
      retryable: transient
    )
  }

  static func postgresStatus(code: PSQLError.Code, sqlState: String?) -> HTTPResponse.Status {
    if let sqlState = sqlState?.uppercased() {
      if sqlState == "57014" { return .gatewayTimeout }
      if sqlState == "57P01" || sqlState == "53300" || sqlState.hasPrefix("08") {
        return .serviceUnavailable
      }
      // A definitive server error takes precedence over generic transport labels.
      return .internalServerError
    }
    switch code {
    case .connectionError, .serverClosedConnection, .clientClosedConnection, .poolClosed, .uncleanShutdown:
      return .serviceUnavailable
    case .queryCancelled:
      return .gatewayTimeout
    default:
      return .internalServerError
    }
  }

  private static func postgresFailure(status: HTTPResponse.Status, requestId: String) -> AppViewFeedError {
    let message: String
    switch status {
    case .gatewayTimeout: message = "The feed request exceeded its deadline."
    case .serviceUnavailable: message = "The feed is temporarily unavailable."
    default: message = "The feed could not be loaded."
    }
    return AppViewFeedError(
      status: status, code: code(for: status), message: message, requestId: requestId,
      retryable: status != .internalServerError)
  }

  private static func postgresError(_ error: any Error) -> PSQLError? {
    if let postgres = error as? PSQLError { return postgres }
    guard let transaction = error as? PostgresTransactionError else { return nil }
    // Preserve the primary failure if rollback also loses its connection.
    return [transaction.closureError, transaction.commitError, transaction.beginError, transaction.rollbackError]
      .compactMap { $0 }.lazy.compactMap(postgresError).first
  }

  private static func code(for status: HTTPResponse.Status) -> String {
    switch status.code {
    case 400: return "invalid_request"
    case 401: return "unauthorized"
    case 403: return "forbidden"
    case 404: return "feed_unavailable"
    case 503: return "feed_dependency_unavailable"
    case 504: return "feed_deadline_exceeded"
    default: return "feed_internal_error"
    }
  }
}

enum AppViewFeedExecution {
  private static let requestDeadline: Duration = .seconds(2)

  static func run<T: Sendable>(
    requestId: String,
    operation: @Sendable @escaping () async throws -> T
  ) async throws -> T {
    let deadline = AppViewFeedQueryDeadline(duration: requestDeadline)
    return try await AppViewFeedQueryDeadline.$current.withValue(deadline) {
      do {
        return try await withDeadline(requestId: requestId, deadline: deadline) {
          do {
            return try await operation()
          } catch {
            try Task.checkCancellation()
            let classified = AppViewFeedErrorClassifier.classify(error, requestId: requestId)
            guard classified.retryable, classified.status == .serviceUnavailable else {
              throw classified
            }
            try await Task.sleep(for: .milliseconds(Int.random(in: 40...120)))
            return try await operation()
          }
        }
      } catch {
        try Task.checkCancellation()
        throw AppViewFeedErrorClassifier.classify(error, requestId: requestId)
      }
    }
  }

  private static func withDeadline<T: Sendable>(
    requestId: String,
    deadline: AppViewFeedQueryDeadline,
    operation: @Sendable @escaping () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      defer { group.cancelAll() }
      group.addTask(operation: operation)
      group.addTask {
        try await ContinuousClock().sleep(until: deadline.instant)
        throw AppViewFeedError(
          status: .gatewayTimeout,
          code: "feed_deadline_exceeded",
          message: "The feed request exceeded its deadline.",
          requestId: requestId,
          retryable: true
        )
      }
      guard let result = try await group.next() else {
        throw CancellationError()
      }
      try deadline.check()
      return result
    }
  }
}
