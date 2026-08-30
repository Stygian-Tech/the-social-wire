import Foundation

public enum IndexingWorkerRole: String, CaseIterable, Sendable, Equatable {
  case projection
  case coordinator
}

public struct IndexingWorkerConfig: Sendable, Equatable {
  public let role: IndexingWorkerRole
  public let host: String
  public let port: Int
  public let appViewHealthPort: Int
  public let wireHealthPort: Int
  public let ownerID: String
  public let leaseDuration: TimeInterval
  public let leaseRenewInterval: TimeInterval
  public let standbyRetryInterval: TimeInterval

  public static func load(
    _ environment: [String: String],
    hostname: String? = nil,
    port: Int? = nil
  ) throws -> IndexingWorkerConfig {
    let rawRole = environment["INDEXING_WORKER_ROLE"]?.lowercased() ?? ""
    guard let role = IndexingWorkerRole(rawValue: rawRole) else {
      throw IndexingWorkerConfigError.invalidRole(rawRole)
    }
    let publicPort: Int
    if let port {
      guard port > 0, port <= 65_535 else {
        throw IndexingWorkerConfigError.invalidPositiveInteger("PORT")
      }
      publicPort = port
    } else {
      publicPort = try positiveInt(environment, key: "PORT", default: 8080)
    }
    let appViewHealthPort = try positiveInt(
      environment, key: "INDEXING_APPVIEW_HEALTH_PORT", default: publicPort + 1
    )
    let wireHealthPort = try positiveInt(
      environment, key: "INDEXING_WIRE_HEALTH_PORT", default: publicPort + 2
    )
    guard Set([publicPort, appViewHealthPort, wireHealthPort]).count == 3 else {
      throw IndexingWorkerConfigError.duplicateHealthPort
    }

    let leaseDuration = try positiveSeconds(
      environment, key: "INDEXING_ROLE_LEASE_SECONDS", default: 30
    )
    let renewInterval = try positiveSeconds(
      environment, key: "INDEXING_ROLE_LEASE_RENEW_SECONDS", default: 10
    )
    let standbyRetryInterval = try positiveSeconds(
      environment, key: "INDEXING_ROLE_STANDBY_RETRY_SECONDS", default: 5
    )
    guard renewInterval < leaseDuration else {
      throw IndexingWorkerConfigError.invalidLeaseTiming
    }

    return IndexingWorkerConfig(
      role: role,
      host: hostname ?? environment["BIND_HOST"] ?? "::",
      port: publicPort,
      appViewHealthPort: appViewHealthPort,
      wireHealthPort: wireHealthPort,
      ownerID: nonEmpty(environment["RAILWAY_REPLICA_ID"])
        ?? nonEmpty(environment["HOSTNAME"])
        ?? ProcessInfo.processInfo.hostName,
      leaseDuration: leaseDuration,
      leaseRenewInterval: renewInterval,
      standbyRetryInterval: standbyRetryInterval
    )
  }

  private static func positiveInt(
    _ environment: [String: String], key: String, default defaultValue: Int
  ) throws -> Int {
    let value: Int
    if let raw = environment[key] {
      guard let parsed = Int(raw) else {
        throw IndexingWorkerConfigError.invalidPositiveInteger(key)
      }
      value = parsed
    } else {
      value = defaultValue
    }
    guard value > 0, value <= 65_535 else {
      throw IndexingWorkerConfigError.invalidPositiveInteger(key)
    }
    return value
  }

  private static func positiveSeconds(
    _ environment: [String: String], key: String, default defaultValue: TimeInterval
  ) throws -> TimeInterval {
    guard let raw = environment[key] else { return defaultValue }
    guard let value = TimeInterval(raw), value > 0 else {
      throw IndexingWorkerConfigError.invalidPositiveSeconds(key)
    }
    return value
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
}

public enum IndexingWorkerConfigError: Error, Sendable, Equatable, CustomStringConvertible {
  case invalidRole(String)
  case invalidPositiveInteger(String)
  case invalidPositiveSeconds(String)
  case duplicateHealthPort
  case invalidLeaseTiming

  public var description: String {
    switch self {
    case .invalidRole(let role):
      "INDEXING_WORKER_ROLE must be projection or coordinator; received '\(role)'."
    case .invalidPositiveInteger(let key): "\(key) must be a positive port number."
    case .invalidPositiveSeconds(let key): "\(key) must be a positive number of seconds."
    case .duplicateHealthPort: "Public and component health ports must be distinct."
    case .invalidLeaseTiming: "Role lease renewal must be shorter than the lease duration."
    }
  }
}
