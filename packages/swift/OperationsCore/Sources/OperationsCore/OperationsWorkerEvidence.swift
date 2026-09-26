import Foundation

/// Role-specific worker evidence during the combined-to-consolidated handoff.
public enum OperationsWorkerEvidence {
  public static func ingestion(
    _ states: [OperationsServiceState], at: Date, validitySeconds: TimeInterval = 15
  ) -> OperationsServiceState? {
    let service = states.contains { $0.service == "projection-pool-appview" }
      ? "projection-pool-appview" : "appview-worker"
    return fresh(service, states: states, at: at, validitySeconds: validitySeconds)
  }

  public static func recovery(
    _ states: [OperationsServiceState], at: Date, validitySeconds: TimeInterval = 15
  ) -> OperationsServiceState? {
    if states.contains(where: { $0.service == "coordinator-appview" }) {
      return activeCoordinator(states, at: at, validitySeconds: validitySeconds)
    }
    return fresh("appview-worker", states: states, at: at, validitySeconds: validitySeconds)
  }

  public static func requiredStates(
    _ states: [OperationsServiceState], at: Date, validitySeconds: TimeInterval
  ) -> [OperationsServiceState] {
    if let projection = fresh(
      "projection-pool-appview", states: states, at: at, validitySeconds: validitySeconds),
      let coordinator = activeCoordinator(states, at: at, validitySeconds: validitySeconds) {
      return [projection, coordinator]
    }
    guard !states.contains(where: {
      $0.service == "projection-pool-appview" || $0.service == "coordinator-appview"
    }) else { return [] }
    return fresh("appview-worker", states: states, at: at, validitySeconds: validitySeconds)
      .map { [$0] } ?? []
  }

  private static func activeCoordinator(
    _ states: [OperationsServiceState], at: Date, validitySeconds: TimeInterval
  ) -> OperationsServiceState? {
    // Postgres validates this marker against the current durable owner/token on read.
    fresh("coordinator-appview", states: states.filter {
      $0.dependencyState["coordinator_authority"] == "active"
        && $0.dependencyState["coordinator_role"] == "indexing.appview-coordinator"
    }, at: at, validitySeconds: validitySeconds)
  }

  private static func fresh(
    _ service: String, states: [OperationsServiceState], at: Date, validitySeconds: TimeInterval
  ) -> OperationsServiceState? {
    // SQLite timestamps round to milliseconds; tolerate subsecond clock/encoding skew.
    states.filter {
      $0.service == service && at.timeIntervalSince($0.heartbeatAt) >= -1
        && at.timeIntervalSince($0.heartbeatAt) <= validitySeconds
    }.max(by: { $0.heartbeatAt < $1.heartbeatAt })
  }
}
