import Foundation
import HTTPTypes
import Hummingbird
import OperationsCore

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
    do {
      return try await withDeadline(requestId: requestId) {
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

  private static func withDeadline<T: Sendable>(
    requestId: String,
    operation: @Sendable @escaping () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask(operation: operation)
      group.addTask {
        try await Task.sleep(for: requestDeadline)
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
      group.cancelAll()
      return result
    }
  }
}
