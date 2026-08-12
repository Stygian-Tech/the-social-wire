import Foundation
import OperationsCore
import SocialWireRedis

public enum RedisOperationsTelemetryAdapter {
  public static func sink(
    telemetry: OperationsTelemetryBuffer?,
    service: String
  ) -> RedisTelemetrySink? {
    guard let telemetry else { return nil }
    return { event in
      let metric: OperationsMetricSample
      switch event.kind {
      case .operation:
        metric = OperationsMetricSample(
          name: "socialwire.redis.operation.duration_seconds",
          value: (event.durationMilliseconds ?? 0) / 1_000,
          dimensions: ["service": service, "operation": event.operation]
        )
      case .error:
        metric = OperationsMetricSample(
          name: "socialwire.redis.errors_total",
          value: 1,
          dimensions: [
            "service": service,
            "operation": event.operation,
            "error_category": event.outcome,
          ]
        )
      case .circuitState:
        metric = OperationsMetricSample(
          name: "socialwire.redis.circuit_state",
          value: event.outcome == "closed" ? 0 : 1,
          dimensions: ["service": service, "state": event.outcome]
        )
      case .cacheLookup:
        metric = OperationsMetricSample(
          name: "socialwire.appview.cache.lookups_total",
          value: 1,
          dimensions: ["service": service, "cache_type": event.operation, "outcome": event.outcome]
        )
      case .lock:
        metric = OperationsMetricSample(
          name: "socialwire.appview.cache.locks_total",
          value: 1,
          dimensions: ["service": service, "operation": event.operation, "outcome": event.outcome]
        )
      case .resourceSample:
        metric = OperationsMetricSample(
          name: "socialwire.redis.\(event.operation)",
          value: event.value ?? 0,
          dimensions: ["service": service]
        )
      }
      Task { _ = await telemetry.enqueue(.metric(metric)) }
    }
  }
}
