import Crypto
import Foundation

public struct RedisKeyNamespace: Sendable, Equatable {
  public let environment: String
  public let version: String

  public init(environment: String, version: String = "v1") {
    self.environment = Self.sanitized(environment)
    self.version = Self.sanitized(version)
  }

  public func key(domain: String, identifiers: [String] = []) -> String {
    let prefix = ["sw", environment, version, Self.sanitized(domain)]
    return (prefix + identifiers.map(Self.digest)).joined(separator: ":")
  }

  public func key(
    domain: String,
    safeComponents: [String],
    identifiers: [String] = []
  ) -> String {
    let prefix = ["sw", environment, version, Self.sanitized(domain)]
    return (prefix + safeComponents.map(Self.boundedSafeComponent) + identifiers.map(Self.digest))
      .joined(separator: ":")
  }

  public func pattern(domain: String, fixedIdentifiers: [String] = []) -> String {
    key(domain: domain, identifiers: fixedIdentifiers) + ":*"
  }

  public static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func sanitized(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let scalars = value.lowercased().unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
    let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return result.isEmpty ? "unknown" : result
  }

  private static func boundedSafeComponent(_ value: String) -> String {
    let normalized = sanitized(value)
    guard value.count <= 64, normalized == value.lowercased() else {
      return digest(value)
    }
    return normalized
  }
}
