import Foundation
import WireCore

struct WireCorpusEdgeConfig: Equatable, Sendable {
  let databaseURL: String
  let sharedSecret: String
  let allowedServiceID: String
  let maximumConnections: Int

  static func load(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws
    -> WireCorpusEdgeConfig
  {
    guard environment["APP_ENV"]?.lowercased() == "prod" else {
      throw WireCorpusEdgeConfigError.productionOnly
    }
    guard let databaseURL = nonempty(environment["DATABASE_URL"]) else {
      throw WireCorpusEdgeConfigError.missingDatabaseURL
    }
    guard let sharedSecret = nonempty(environment["WIRE_CORPUS_EDGE_SHARED_SECRET"]) else {
      throw WireCorpusEdgeConfigError.missingSharedSecret
    }
    guard sharedSecret.utf8.count >= 32 else {
      throw WireCorpusEdgeConfigError.invalidSharedSecret
    }
    guard let allowedServiceID = nonempty(environment["WIRE_CORPUS_EDGE_ALLOWED_SERVICE_ID"]) else {
      throw WireCorpusEdgeConfigError.missingAllowedServiceID
    }
    do {
      try WireCorpusServiceTrust.validateServiceID(allowedServiceID)
    } catch {
      throw WireCorpusEdgeConfigError.invalidAllowedServiceID
    }
    let maximumConnections = environment["WIRE_CORPUS_EDGE_POSTGRES_MAX_CONNECTIONS"]
      .flatMap(Int.init)
      .map { max(2, min($0, 8)) } ?? 4
    return WireCorpusEdgeConfig(
      databaseURL: databaseURL,
      sharedSecret: sharedSecret,
      allowedServiceID: allowedServiceID,
      maximumConnections: maximumConnections
    )
  }

  private static func nonempty(_ raw: String?) -> String? {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }
}
