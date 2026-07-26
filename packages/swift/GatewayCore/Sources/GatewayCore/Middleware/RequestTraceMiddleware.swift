import Foundation
import HTTPTypes
import Hummingbird
import OperationsCore

public struct RequestTraceMiddleware: RouterMiddleware {
  public typealias Context = GatewayRequestContext

  private let service: String
  private let environment: String
  private let instanceId: String
  private let telemetry: OperationsTelemetryBuffer?

  public init(
    service: String,
    environment: String,
    instanceId: String,
    telemetry: OperationsTelemetryBuffer? = nil
  ) {
    self.service = service
    self.environment = environment
    self.instanceId = instanceId
    self.telemetry = telemetry
  }

  public func handle(
    _ request: Request,
    context: GatewayRequestContext,
    next: (Request, GatewayRequestContext) async throws -> Response
  ) async throws -> Response {
    let requestHeader = HTTPField.Name("X-Request-ID")
    let traceHeader = HTTPField.Name("traceparent")
    var mutableContext = context
    mutableContext.requestId = requestHeader.flatMap { request.headers[$0] }
      .flatMap(Self.safeRequestId) ?? UUID().uuidString.lowercased()

    let incoming = traceHeader.flatMap { request.headers[$0] }.flatMap(TraceContext.init(traceparent:))
    let routeSampleRate = request.uri.path.contains("bootstrap-stream") ? 10 : 5
    mutableContext.traceContext = incoming?.child()
      ?? TraceContext(sampled: Int.random(in: 0..<100) < routeSampleRate)

    let startedAt = Date()
    do {
      var response = try await next(request, mutableContext)
      let duration = Date().timeIntervalSince(startedAt)
      await record(request: request, context: mutableContext, startedAt: startedAt, duration: duration, statusCode: response.status.code, errorType: nil)
      if let requestHeader { response.headers[requestHeader] = mutableContext.requestId }
      if let traceHeader { response.headers[traceHeader] = mutableContext.traceContext.traceparent }
      return response
    } catch {
      let statusCode = Self.statusCode(for: error)
      let errorType = statusCode >= 500 ? OperationsRedactor.errorCategory(error) : nil
      await record(
        request: request,
        context: mutableContext,
        startedAt: startedAt,
        duration: Date().timeIntervalSince(startedAt),
        statusCode: statusCode,
        errorType: errorType
      )
      if var httpError = error as? HTTPError {
        if let requestHeader { httpError.headers[requestHeader] = mutableContext.requestId }
        if let traceHeader { httpError.headers[traceHeader] = mutableContext.traceContext.traceparent }
        throw httpError
      }
      throw error
    }
  }

  static func statusCode(for error: any Error) -> Int {
    (error as? any HTTPResponseError)?.status.code ?? 500
  }

  private static func safeRequestId(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 128,
          trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E })
    else { return nil }
    return trimmed
  }

  private func record(
    request: Request,
    context: GatewayRequestContext,
    startedAt: Date,
    duration: TimeInterval,
    statusCode: Int,
    errorType: String?
  ) async {
    guard let telemetry else { return }
    let route = Self.routeTemplate(request.uri.path)
    let statusClass = "\(statusCode / 100)xx"
    let dimensions = [
      "service": service,
      "environment": environment,
      "route_template": route,
      "method": request.method.rawValue,
      "status_class": statusClass,
    ]
    _ = await telemetry.enqueue(.metric(.init(name: "socialwire.http.server.requests_total", value: 1, dimensions: dimensions)))
    _ = await telemetry.enqueue(.metric(.init(name: "socialwire.http.server.duration_seconds", value: duration, dimensions: dimensions)))
    let isError = statusCode >= 500
    if context.traceContext.sampled || isError {
      var attributes = dimensions
      if let errorType { attributes["error_type"] = errorType }
      _ = await telemetry.enqueue(.span(.init(
        environment: environment,
        traceId: context.traceContext.traceId,
        parentSpanId: nil,
        service: service,
        name: "\(service).request",
        startedAt: startedAt,
        durationMs: duration * 1_000,
        status: isError ? "error" : "ok",
        attributes: attributes,
        expiresAt: startedAt.addingTimeInterval(isError ? 30 * 86_400 : 7 * 86_400)
      )))
    }
  }

  static func routeTemplate(_ path: String) -> String {
    var components = path.split(separator: "/").map(String.init)
    guard components.count >= 2, components[0] == "v1" else {
      return Self.normalizedFallbackPath(path)
    }

    if
      components.count >= 4,
      components[1] == "operations",
      ["gaps", "backfills", "alerts", "traces"].contains(components[2])
    {
      components[3] = ":id"
    } else if
      components.count >= 4,
      components[1] == "publications",
      ["folders", "subscriptions", "rss-subscriptions"].contains(components[2])
    {
      components[3] = ":rkey"
    } else if
      components.count >= 4,
      components[1] == "latr",
      components[2] == "saves"
    {
      components[3] = ":rkey"
    }
    return "/" + components.joined(separator: "/")
  }

  private static func normalizedFallbackPath(_ path: String) -> String {
    let normalized = path.split(separator: "/").prefix(6).map { component -> String in
      let value = String(component)
      if value.count > 48 || value.hasPrefix("did:") || value.hasPrefix("at:") {
        return ":id"
      }
      return value
    }
    let result = "/" + normalized.joined(separator: "/")
    return String(result.prefix(160))
  }
}
