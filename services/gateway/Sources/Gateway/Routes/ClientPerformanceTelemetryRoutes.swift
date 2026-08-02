import Foundation
import GatewayCore
import Hummingbird
import OperationsCore

struct ClientPerformanceTelemetryRoutes {
  let telemetry: OperationsTelemetryBuffer?
  let environment: String

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.post("/v1/telemetry/client-performance") { request, context async throws -> HTTPResponse.Status in
      guard context.authContext != nil else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: ClientPerformanceRequest.self, context: context)
      guard body.durationMs.isFinite, (0...60_000).contains(body.durationMs),
            ["aggregate", "publication"].contains(body.feedType),
            ["hit", "miss"].contains(body.cacheState),
            ["success", "error"].contains(body.outcome),
            ["local", "dev", "test", "production"].contains(body.environment)
      else {
        throw HTTPError(.badRequest, message: "Invalid client performance sample")
      }

      let region = ProcessInfo.processInfo.environment["FLY_REGION"] == "iah" ? "iah" : "unknown"
      let dimensions = [
        "event": body.event.rawValue,
        "feed_type": body.feedType,
        "cache_state": body.cacheState,
        "outcome": body.outcome,
        "environment": environment,
        "deployment_region": region,
      ]
      _ = await telemetry?.enqueue(.metric(.init(
        name: "socialwire.reader.client.duration_ms",
        value: body.durationMs,
        dimensions: dimensions
      )))
      for upperBound in [50, 100, 150, 250, 500, 1_000, 2_000, 5_000]
      where body.durationMs <= Double(upperBound) {
        var bucketDimensions = dimensions
        bucketDimensions["le_ms"] = String(upperBound)
        _ = await telemetry?.enqueue(.metric(.init(
          name: "socialwire.reader.client.duration_bucket",
          value: 1,
          dimensions: bucketDimensions
        )))
      }
      return .accepted
    }
  }
}
