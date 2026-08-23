import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
import WireCore

enum WireCorpusEdgeRouterBuilder {
  static func router(
    store: any WireCorpusStoring,
    config: WireCorpusEdgeConfig,
    logger: Logger,
    replayGuard: WireCorpusReplayGuard = WireCorpusReplayGuard()
  ) -> Router<WireCorpusEdgeRequestContext> {
    let router = Router(context: WireCorpusEdgeRequestContext.self)
    router.add(middleware: WireCorpusEdgeErrorMiddleware())
    router.get("/health") { _, _ in ["service": "wire-corpus-edge", "status": "live"] }
    router.get("/livez") { _, _ in ["service": "wire-corpus-edge", "status": "live"] }
    router.get("/readyz") { _, _ async throws -> [String: String] in
      try await store.ping()
      try await store.requireFreshBaseline(now: Date())
      return ["service": "wire-corpus-edge", "status": "ready"]
    }

    let protected = router.group()
      .add(
        middleware: WireCorpusEdgeAuthMiddleware(
          secret: config.sharedSecret,
          allowedServiceID: config.allowedServiceID,
          replayGuard: replayGuard,
          logger: logger
        )
      )

    protected.get("/internal/wire/v1/contract") { request, _ async throws -> Response in
      try validateQuery(request.uri.query, allowed: [])
      try await store.ping()
      return try response(["contractVersion": 2])
    }
    protected.get("/internal/wire/v1/feed") { request, _ async throws -> Response in
      try validateQuery(
        request.uri.query,
        allowed: ["generationId", "language", "limit", "startOrdinal"]
      )
      let language = primaryLanguage(request.uri.queryParameters.get("language"))
      let generationID: UUID?
      if let raw = request.uri.queryParameters.get("generationId") {
        guard let parsed = UUID(uuidString: raw) else {
          throw WireCorpusEdgeRequestError.invalidRequest
        }
        generationID = parsed
      } else {
        generationID = nil
      }
      let startOrdinal = try boundedInt(
        request.uri.queryParameters.get("startOrdinal"),
        default: 0,
        range: 0...10_000_000
      )
      let limit = try boundedInt(
        request.uri.queryParameters.get("limit"),
        default: 500,
        range: 1...500
      )
      return try response(
        await store.feed(
          language: language,
          generationID: generationID,
          startOrdinal: startOrdinal,
          limit: limit,
          now: Date()
        )
      )
    }
    protected.get("/internal/wire/v1/edition") { request, _ async throws -> Response in
      try validateQuery(request.uri.query, allowed: ["language", "region"])
      return try response(
        await store.edition(
          language: primaryLanguage(request.uri.queryParameters.get("language")),
          region: request.uri.queryParameters.get("region")
            .flatMap(WireViewerRegion.init(rawValue:)),
          now: Date()
        )
      )
    }
    protected.get("/internal/wire/v1/item") { request, _ async throws -> Response in
      try validateQuery(request.uri.query, allowed: ["itemId"])
      guard let itemID = request.uri.queryParameters.get("itemId"),
        !itemID.isEmpty, itemID.utf8.count <= 128
      else {
        throw WireCorpusEdgeRequestError.invalidRequest
      }
      guard let item = try await store.item(id: itemID, now: Date()) else {
        throw WireCorpusEdgeRequestError.notFound
      }
      return try response(item)
    }
    protected.get("/internal/wire/v1/catalog") { request, _ async throws -> Response in
      try validateQuery(request.uri.query, allowed: [])
      return try response(await store.catalog(now: Date()))
    }
    return router
  }

  private static func response<Value: Encodable>(_ value: Value) throws -> Response {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let body = try encoder.encode(value)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[.cacheControl] = "no-store"
    if let name = HTTPField.Name("X-Wire-Corpus-Contract") { headers[name] = "2" }
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: body)))
  }

  private static func boundedInt(
    _ raw: String?,
    default defaultValue: Int,
    range: ClosedRange<Int>
  ) throws -> Int {
    guard let raw else { return defaultValue }
    guard let value = Int(raw), range.contains(value) else {
      throw WireCorpusEdgeRequestError.invalidRequest
    }
    return value
  }

  private static func primaryLanguage(_ raw: String?) -> String {
    guard let raw else { return "und" }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let primary = normalized.split(separator: "-").first,
      primary.count >= 2, primary.count <= 8,
      primary.allSatisfy({ $0.isASCII && $0.isLetter })
    else { return "und" }
    return String(primary)
  }

  private static func validateQuery(_ raw: String?, allowed: Set<String>) throws {
    guard let raw, !raw.isEmpty else { return }
    var names = Set<String>()
    for component in raw.split(separator: "&", omittingEmptySubsequences: false) {
      guard !component.isEmpty else { throw WireCorpusEdgeRequestError.invalidRequest }
      let encodedName = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
      guard let name = String(encodedName).removingPercentEncoding,
        allowed.contains(name), names.insert(name).inserted
      else {
        throw WireCorpusEdgeRequestError.invalidRequest
      }
    }
  }
}
