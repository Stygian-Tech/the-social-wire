import FinanceCore
import Foundation

struct FinanceDiscoveryConfig: Sendable {
  let mode: FinanceFeedMode
  let cursorSecret: String?
  let widgetsEnabled: Bool
  let catalogRightsConfirmed: Bool
  let openFIGIKey: String?
  var corpusEdge: WireCorpusRemoteConfig? = nil
  var providerPolicy = FinanceCatalogProviderPolicy(environment: [:])

  static let disabled = Self(mode: .off, cursorSecret: nil, widgetsEnabled: false, catalogRightsConfirmed: false, openFIGIKey: nil)

  static func fromEnvironment(_ env: [String: String]) throws -> Self {
    let raw = env["FINANCE_FEED_MODE"]?.lowercased() ?? "off"
    guard let mode = FinanceFeedMode(rawValue: raw) else {
      throw WireDiscoveryConfigError.invalidMode(raw)
    }
    let corpusEdge = try WireCorpusRemoteConfig.fromEnvironment([
      "APP_ENV": env["APP_ENV"] ?? "",
      "WIRE_CORPUS_EDGE_BASE_URL": env["FINANCE_CORPUS_EDGE_BASE_URL"] ?? "",
      "WIRE_CORPUS_EDGE_SERVICE_ID": env["FINANCE_CORPUS_EDGE_SERVICE_ID"] ?? "",
      "WIRE_CORPUS_EDGE_HMAC_SECRET": env["FINANCE_CORPUS_EDGE_HMAC_SECRET"] ?? "",
    ])
    return Self(mode: mode,
      cursorSecret: env["FINANCE_CURSOR_HMAC_SECRET"] ?? env["WIRE_CURSOR_HMAC_SECRET"],
      widgetsEnabled: env["FINANCE_WIDGETS_ENABLED"]?.lowercased() == "true",
      catalogRightsConfirmed: env["FINANCE_CATALOG_RIGHTS_CONFIRMED"]?.lowercased() == "true",
      openFIGIKey: env["OPENFIGI_API_KEY"], corpusEdge: corpusEdge, providerPolicy: .init(environment: env))
  }
}
