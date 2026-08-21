import Foundation
import WireCore

struct WireCorpusRemoteConfig: Equatable, Sendable {
  let baseURL: String
  let serviceID: String
  let sharedSecret: String

  static func fromEnvironment(_ environment: [String: String]) throws -> WireCorpusRemoteConfig? {
    let rawValues = [
      environment["WIRE_CORPUS_EDGE_BASE_URL"],
      environment["WIRE_CORPUS_EDGE_SERVICE_ID"],
      environment["WIRE_CORPUS_EDGE_HMAC_SECRET"],
    ]
    guard rawValues.contains(where: { nonempty($0) != nil }) else { return nil }
    guard
      let rawBaseURL = nonempty(rawValues[0]),
      let serviceID = nonempty(rawValues[1]),
      let sharedSecret = nonempty(rawValues[2])
    else {
      throw WireDiscoveryConfigError.incompleteCorpusEdgeConfiguration
    }
    guard sharedSecret.utf8.count >= 32 else {
      throw WireDiscoveryConfigError.invalidCorpusEdgeSecret
    }
    do {
      try WireCorpusServiceTrust.validateServiceID(serviceID)
    } catch {
      throw WireDiscoveryConfigError.invalidCorpusEdgeServiceID
    }
    guard let url = URL(string: rawBaseURL), let scheme = url.scheme?.lowercased(),
      let host = url.host?.lowercased(), !host.isEmpty,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.isEmpty || url.path == "/"
    else {
      throw WireDiscoveryConfigError.invalidCorpusEdgeBaseURL
    }
    let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
    let isLocal = environment["APP_ENV"]?.lowercased() == "local"
    guard scheme == "https" || (scheme == "http" && isLoopback && isLocal) else {
      throw WireDiscoveryConfigError.invalidCorpusEdgeBaseURL
    }
    var origin = URLComponents()
    origin.scheme = scheme
    origin.host = host
    origin.port = url.port
    guard let normalized = origin.url?.absoluteString else {
      throw WireDiscoveryConfigError.invalidCorpusEdgeBaseURL
    }
    return WireCorpusRemoteConfig(
      baseURL: normalized,
      serviceID: serviceID,
      sharedSecret: sharedSecret
    )
  }

  private static func nonempty(_ raw: String?) -> String? {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }
}
