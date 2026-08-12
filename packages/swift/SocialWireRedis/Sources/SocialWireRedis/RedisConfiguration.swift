import Foundation

public struct RedisConfiguration: Sendable, Equatable {
  public enum Scheme: String, Sendable {
    case redis
    case rediss
  }

  public let scheme: Scheme
  public let host: String
  public let port: Int
  public let username: String?
  public let password: String?
  public let database: Int?
  public let minimumConnectionCount: Int
  public let maximumConnectionCount: Int
  public let commandTimeoutMilliseconds: Int

  public var usesTLS: Bool { scheme == .rediss }

  public init(
    url: String,
    minimumConnectionCount: Int = 1,
    maximumConnectionCount: Int = 8,
    commandTimeoutMilliseconds: Int = 250
  ) throws {
    guard let components = URLComponents(string: url),
          let rawScheme = components.scheme,
          let scheme = Scheme(rawValue: rawScheme.lowercased()),
          let host = components.host,
          !host.isEmpty
    else {
      throw RedisConfigurationError.invalidURL
    }
    guard minimumConnectionCount > 0,
          maximumConnectionCount >= minimumConnectionCount,
          commandTimeoutMilliseconds > 0
    else {
      throw RedisConfigurationError.invalidPoolConfiguration
    }

    let database: Int?
    let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if path.isEmpty {
      database = nil
    } else if let parsed = Int(path), parsed >= 0 {
      database = parsed
    } else {
      throw RedisConfigurationError.invalidDatabase
    }

    self.scheme = scheme
    self.host = host
    self.port = components.port ?? 6379
    self.username = components.user?.isEmpty == false ? components.user : nil
    self.password = components.password?.isEmpty == false ? components.password : nil
    self.database = database
    self.minimumConnectionCount = minimumConnectionCount
    self.maximumConnectionCount = maximumConnectionCount
    self.commandTimeoutMilliseconds = commandTimeoutMilliseconds
  }
}
