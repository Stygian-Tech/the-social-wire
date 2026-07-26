import Foundation

public struct OperationsConfiguration: Sendable {
  public let enabled: Bool
  public let recoveryEnabled: Bool
  public let alertDeliveryEnabled: Bool
  public let environment: String
  public let instanceId: String
  public let operatorDids: Set<String>
  public let webhookURL: String?
  public let webhookSecret: String?
  public let backfillFingerprintSecret: String?
  public let replayRewindMicroseconds: Int64
  public let disconnectAlertSeconds: TimeInterval
  public let idleAlertSeconds: TimeInterval
  public let commitStaleSeconds: TimeInterval
  public let backlogAlertMicroseconds: Int64
  public let backfillStallSeconds: TimeInterval
  public let indexFailureRatio: Double
  public let indexFailureMinimum: Int
  public let appView5xxRatio: Double
  public let appView5xxMinimumRequests: Int
  public let bootstrapP95Seconds: TimeInterval
  public let entriesP95Seconds: TimeInterval
  public let unreadCountsP95Seconds: TimeInterval
  public let sidebarP95Seconds: TimeInterval
  public let databaseQueryP95Seconds: TimeInterval
  public let responseFreshnessSeconds: TimeInterval
  public let responseFreshnessRatio: Double

  public static func fromEnvironment(_ environment: [String: String]) -> OperationsConfiguration {
    let operatorDids = Set(
      (environment["OPERATIONS_OPERATOR_DIDS"] ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )
    return OperationsConfiguration(
      enabled: truthy(environment["OPERATIONS_TELEMETRY_ENABLED"], defaultValue: true),
      recoveryEnabled: truthy(environment["OPERATIONS_RECOVERY_ENABLED"]),
      alertDeliveryEnabled: truthy(environment["OPERATIONS_ALERT_DELIVERY_ENABLED"]),
      environment: nonEmpty(environment["APP_ENV"]) ?? "__missing__",
      instanceId: environment["FLY_MACHINE_ID"] ?? ProcessInfo.processInfo.hostName,
      operatorDids: operatorDids,
      webhookURL: nonEmpty(environment["OPERATIONS_ALERT_WEBHOOK_URL"]),
      webhookSecret: nonEmpty(environment["OPERATIONS_ALERT_WEBHOOK_SECRET"]),
      backfillFingerprintSecret: nonEmpty(environment["OPERATIONS_BACKFILL_FINGERPRINT_SECRET"])
        ?? nonEmpty(environment["GATEWAY_OPERATIONS_INTERNAL_SECRET"]),
      replayRewindMicroseconds: int64(environment["OPERATIONS_REPLAY_REWIND_MICROSECONDS"], 5_000_000),
      disconnectAlertSeconds: seconds(environment["OPERATIONS_DISCONNECT_ALERT_SECONDS"], 120),
      idleAlertSeconds: seconds(environment["OPERATIONS_IDLE_ALERT_SECONDS"], 300),
      commitStaleSeconds: seconds(environment["OPERATIONS_COMMIT_STALE_SECONDS"], 300),
      backlogAlertMicroseconds: int64(environment["OPERATIONS_BACKLOG_ALERT_MICROSECONDS"], 60_000_000),
      backfillStallSeconds: seconds(environment["OPERATIONS_BACKFILL_STALL_SECONDS"], 600),
      indexFailureRatio: ratio(environment["OPERATIONS_INDEX_FAILURE_RATIO"], 0.01),
      indexFailureMinimum: integer(environment["OPERATIONS_INDEX_FAILURE_MINIMUM"], 10),
      appView5xxRatio: ratio(environment["OPERATIONS_APPVIEW_5XX_RATIO"], 0.02),
      appView5xxMinimumRequests: integer(environment["OPERATIONS_APPVIEW_5XX_MINIMUM_REQUESTS"], 20),
      bootstrapP95Seconds: seconds(environment["OPERATIONS_BOOTSTRAP_P95_SECONDS"], 5),
      entriesP95Seconds: seconds(environment["OPERATIONS_ENTRIES_P95_SECONDS"], 2),
      unreadCountsP95Seconds: seconds(environment["OPERATIONS_UNREAD_COUNTS_P95_SECONDS"], 1.5),
      sidebarP95Seconds: seconds(environment["OPERATIONS_SIDEBAR_P95_SECONDS"], 3),
      databaseQueryP95Seconds: seconds(environment["OPERATIONS_DATABASE_QUERY_P95_SECONDS"], 1),
      responseFreshnessSeconds: seconds(environment["OPERATIONS_RESPONSE_FRESHNESS_SECONDS"], 300),
      responseFreshnessRatio: ratio(environment["OPERATIONS_RESPONSE_FRESHNESS_RATIO"], 0.05)
    )
  }

  public static func requireEnvironment(_ environment: [String: String]) throws -> String {
    try requireEnvironment(environment["APP_ENV"])
  }

  public static func requireEnvironment(_ value: String?) throws -> String {
    guard let value = nonEmpty(value)?.lowercased(), ["dev", "prod"].contains(value) else {
      throw OperationsConfigurationError.invalidOrMissingEnvironment
    }
    return value
  }

  private static func truthy(_ value: String?, defaultValue: Bool = false) -> Bool {
    guard let value else { return defaultValue }
    return ["1", "true", "yes", "on"].contains(value.lowercased())
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private static func seconds(_ value: String?, _ fallback: TimeInterval) -> TimeInterval {
    guard let value, let parsed = TimeInterval(value), parsed > 0 else { return fallback }
    return parsed
  }

  private static func int64(_ value: String?, _ fallback: Int64) -> Int64 {
    guard let value, let parsed = Int64(value), parsed > 0 else { return fallback }
    return parsed
  }

  private static func integer(_ value: String?, _ fallback: Int) -> Int {
    guard let value, let parsed = Int(value), parsed > 0 else { return fallback }
    return parsed
  }

  private static func ratio(_ value: String?, _ fallback: Double) -> Double {
    guard let value, let parsed = Double(value), parsed > 0, parsed <= 1 else { return fallback }
    return parsed
  }
}

public enum OperationsConfigurationError: Error, Sendable, Equatable {
  case invalidOrMissingEnvironment
}
