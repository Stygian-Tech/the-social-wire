import Foundation

public enum TapConsumerMode: String, Sendable, Equatable {
  case disabled
  case shadow
  case authoritative
}

public enum TapConsumerConfigurationError: Error, CustomStringConvertible, Equatable, Sendable {
  case missingEnvironment
  case missingAdminPassword
  case invalidBaseURL
  case invalidMode(String)

  public var description: String {
    switch self {
    case .missingEnvironment:
      return "APP_ENV is required when the Tap consumer is enabled."
    case .missingAdminPassword:
      return "TAP_ADMIN_PASSWORD is required when the Tap consumer is enabled."
    case .invalidBaseURL:
      return "TAP_BASE_URL must be an absolute HTTP or HTTPS URL."
    case .invalidMode(let value):
      return "TAP_CONSUMER_MODE must be disabled, shadow, or authoritative (received \(value))."
    }
  }
}

/// Staged Tap configuration. `shadow` is the safe default for an explicitly enabled consumer.
public struct TapConsumerConfiguration: Sendable, Equatable {
  public static let registeredCollections = [
    "site.standard.document",
    "site.standard.entry",
  ]

  public let mode: TapConsumerMode
  public let environment: String
  public let baseURL: URL
  public let channelURL: URL
  public let adminPassword: String
  public let collections: [String]
  public let queueCapacity: Int
  public let repoSyncIntervalSeconds: TimeInterval
  public let repoSyncLimit: Int

  public init(
    mode: TapConsumerMode,
    environment: String,
    baseURL: URL,
    channelURL: URL,
    adminPassword: String,
    collections: [String] = Self.registeredCollections,
    queueCapacity: Int = 4_096,
    repoSyncIntervalSeconds: TimeInterval = 300,
    repoSyncLimit: Int = 10_000
  ) {
    self.mode = mode
    self.environment = environment
    self.baseURL = baseURL
    self.channelURL = channelURL
    self.adminPassword = adminPassword
    self.collections = collections
    self.queueCapacity = max(1, queueCapacity)
    self.repoSyncIntervalSeconds = max(5, repoSyncIntervalSeconds)
    self.repoSyncLimit = max(1, repoSyncLimit)
  }

  public static func fromEnvironment(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> TapConsumerConfiguration {
    let rawMode = env["TAP_CONSUMER_MODE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? TapConsumerMode.disabled.rawValue
    guard let mode = TapConsumerMode(rawValue: rawMode) else {
      throw TapConsumerConfigurationError.invalidMode(rawMode)
    }

    let rawEnvironment = env["APP_ENV"]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let rawPassword = env["TAP_ADMIN_PASSWORD"]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if mode != .disabled, rawEnvironment.isEmpty {
      throw TapConsumerConfigurationError.missingEnvironment
    }
    if mode != .disabled, rawPassword.isEmpty {
      throw TapConsumerConfigurationError.missingAdminPassword
    }

    let rawBase = env["TAP_BASE_URL"]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "http://127.0.0.1:2480"
    guard
      let baseURL = URL(string: rawBase),
      let scheme = baseURL.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      baseURL.host != nil
    else { throw TapConsumerConfigurationError.invalidBaseURL }

    var channelComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    channelComponents?.scheme = scheme == "https" ? "wss" : "ws"
    channelComponents?.path = "/channel"
    channelComponents?.query = nil
    guard let channelURL = channelComponents?.url else {
      throw TapConsumerConfigurationError.invalidBaseURL
    }

    let collections = (env["TAP_COLLECTION_FILTERS"] ?? "")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { Self.registeredCollections.contains($0) }
    let configuredCollections = collections.isEmpty ? registeredCollections : Array(Set(collections)).sorted()

    return TapConsumerConfiguration(
      mode: mode,
      environment: rawEnvironment.isEmpty ? "disabled" : rawEnvironment,
      baseURL: baseURL,
      channelURL: channelURL,
      adminPassword: rawPassword,
      collections: configuredCollections,
      queueCapacity: positiveInt(env["TAP_CONSUMER_QUEUE_CAPACITY"], default: 4_096),
      repoSyncIntervalSeconds: positiveSeconds(
        env["TAP_REPO_SYNC_INTERVAL_SECONDS"],
        default: 300
      ),
      repoSyncLimit: positiveInt(env["TAP_REPO_SYNC_LIMIT"], default: 10_000)
    )
  }

  private static func positiveInt(_ raw: String?, default fallback: Int) -> Int {
    guard let raw, let value = Int(raw), value > 0 else { return fallback }
    return value
  }

  private static func positiveSeconds(
    _ raw: String?,
    default fallback: TimeInterval
  ) -> TimeInterval {
    guard let raw, let value = TimeInterval(raw), value > 0 else { return fallback }
    return value
  }
}
