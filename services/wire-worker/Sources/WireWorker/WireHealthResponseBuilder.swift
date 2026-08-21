import NIOHTTP1

enum WireHealthResponseBuilder {
  struct Response: Equatable, Sendable {
    let status: HTTPResponseStatus
    let body: String
  }

  static func response(
    method: HTTPMethod,
    uri: String,
    databaseProbe: @escaping @Sendable () async throws -> Void,
    readinessProbe: (@Sendable () async throws -> Void)? = nil
  ) async -> Response {
    guard method == .GET else {
      return .init(status: .methodNotAllowed, body: #"{"error":"method_not_allowed"}"#)
    }
    let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
    switch path {
    case "/health", "/livez":
      return .init(status: .ok, body: #"{"service":"wire-worker","status":"live"}"#)
    case "/startupz":
      do {
        try await databaseProbe()
        return .init(status: .ok, body: #"{"service":"wire-worker","status":"ready"}"#)
      } catch {
        return .init(status: .serviceUnavailable, body: #"{"service":"wire-worker","status":"unavailable"}"#)
      }
    case "/readyz":
      do {
        try await databaseProbe()
        try await readinessProbe?()
        return .init(status: .ok, body: #"{"service":"wire-worker","status":"ready"}"#)
      } catch {
        return .init(status: .serviceUnavailable, body: #"{"service":"wire-worker","status":"unavailable"}"#)
      }
    default:
      return .init(status: .notFound, body: #"{"error":"not_found"}"#)
    }
  }
}
