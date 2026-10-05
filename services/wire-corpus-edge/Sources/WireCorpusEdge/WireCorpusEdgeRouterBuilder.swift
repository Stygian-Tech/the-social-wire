import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
import WireCore
import SportsCore

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
      return try response(["contractVersion": 3])
    }
    protected.get("/internal/wire/v1/finance") { request, _ async throws -> Response in
      try validateQuery(request.uri.query, allowed: ["language"])
      let now = Date()
      try await store.requireFreshBaseline(now: now)
      return try response(await store.finance(language: primaryLanguage(request.uri.queryParameters.get("language")), now: now))
    }
    protected.get("/internal/wire/v1/sports/schedules") { request, _ async throws -> Response in
      try validateQuery(request.uri.query, allowed: [])
      return try response(await store.sportsSchedules(now: Date()))
    }
    protected.get("/internal/wire/v1/sports/standings") { request, _ async throws -> Response in
      try validateQuery(request.uri.query, allowed: ["preferredIDs"])
      let raw = request.uri.queryParameters.get("preferredIDs") ?? ""
      let ids = raw.isEmpty ? [] : raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
      guard ids.count <= 100, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && $0.range(of: "^[a-zA-Z0-9:_-]+$", options: .regularExpression) != nil }) else { throw HTTPError(.badRequest) }
      return try response(await store.sportsStandings(now: Date(), preferredIDs: ids))
    }
    protected.get("/internal/wire/v1/sports/events") { request, _ async throws -> Response in
      try validateQuery(request.uri.query, allowed: ["competitionIDs", "entityIDs", "global", "teamIDs", "preferredIDs", "timeZone"])
      func identifiers(_ key: String) throws -> [String] {
        guard let raw = request.uri.queryParameters.get(key) else { return [] }
        if ["teamIDs", "preferredIDs"].contains(key), raw.isEmpty { return [] }
        let values = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard values.count <= (["teamIDs", "preferredIDs"].contains(key) ? 100 : 200), values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= (["teamIDs", "preferredIDs"].contains(key) ? 128 : 256) && $0.range(of: "^[a-zA-Z0-9:_-]+$", options: .regularExpression) != nil }) else { throw HTTPError(.badRequest) }
        return values
      }
      let timeZoneName = request.uri.queryParameters.get("timeZone") ?? "Etc/UTC"
      guard timeZoneName.utf8.count <= 128, (TimeZone.knownTimeZoneIdentifiers.contains(timeZoneName) || ["UTC", "GMT", "Etc/UTC", "Etc/GMT"].contains(timeZoneName)), let timeZone = TimeZone(identifier: timeZoneName) else { throw HTTPError(.badRequest) }
      let global = request.uri.queryParameters.get("global")
      guard global == nil || ["true", "false"].contains(global!) else { throw HTTPError(.badRequest) }
      return try response(await store.sportsEvents(now: Date(), competitionIDs: identifiers("competitionIDs"), entityIDs: identifiers("entityIDs"), global: global != "false", teamIDs: request.uri.queryParameters.get("teamIDs") == nil ? nil : identifiers("teamIDs"), preferredIDs: identifiers("preferredIDs"), timeZone: timeZone))
    }
    protected.get("/internal/wire/v1/sports") { request, _ async throws -> Response in
      try validateQuery(request.uri.query, allowed: ["language"])
      let now = Date()
      try await store.requireFreshBaseline(now: now)
      let source = try await store.sports(language: primaryLanguage(request.uri.queryParameters.get("language")), now: now)
      guard SportsCandidateVersionPolicy.isCurrent(source.candidates) else { throw WireCorpusEdgeStoreError.unavailable }
      return try response(source)
    }
    protected.get("/internal/wire/v1/feed") { request, _ async throws -> Response in
      try validateQuery(
        request.uri.query,
        allowed: ["generationId", "language", "limit", "startOrdinal", "fallbackLimit"]
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
          fallbackLimit: try request.uri.queryParameters.get("fallbackLimit").map {
            try boundedInt($0, default: 500, range: 1...5000)
          },
          now: Date()
        )
      )
    }
    protected.get("/internal/wire/v1/edition") { request, _ async throws -> Response in
      try validateQuery(request.uri.query, allowed: ["language", "region", "fallbackLimit"])
      return try response(
        await store.edition(
          language: primaryLanguage(request.uri.queryParameters.get("language")),
          region: request.uri.queryParameters.get("region")
            .flatMap(WireViewerRegion.init(rawValue:)),
          fallbackLimit: try request.uri.queryParameters.get("fallbackLimit").map {
            try boundedInt($0, default: 50, range: 1...5000)
          },
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
    protected.post("/internal/wire/v1/circle-candidates") { request, _ async throws -> Response in
      try validateQuery(request.uri.query, allowed: [])
      let bodyBuffer = try await request.body.collect(upTo: 1 * 1_024 * 1_024)
      let body = Data(buffer: bodyBuffer)
      guard
        let digestName = HTTPField.Name(WireCorpusServiceTrust.bodyDigestHeaderName),
        let presentedDigest = request.headers[digestName],
        presentedDigest == WireCorpusServiceTrust.bodyDigest(body)
      else {
        throw WireCorpusEdgeRequestError.unauthorized
      }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      guard let input = try? decoder.decode(WireCorpusCandidateRequest.self, from: body) else {
        throw WireCorpusEdgeRequestError.invalidRequest
      }
      let uniqueActors = Array(Set(input.actorHashes))
      let now = Date()
      guard !uniqueActors.isEmpty,
        uniqueActors.count == input.actorHashes.count,
        uniqueActors.count <= WireCorpusCandidateRequest.maximumActorHashesPerRequest,
        uniqueActors.allSatisfy(validActorHash),
        (1...WireCorpusCandidateRequest.maximumStoriesPerRequest).contains(input.limit),
        input.since <= now.addingTimeInterval(60),
        input.since >= now.addingTimeInterval(-7 * 24 * 60 * 60)
      else {
        throw WireCorpusEdgeRequestError.invalidRequest
      }
      return try response(
        await store.circleCandidates(
          actorHashes: uniqueActors,
          language: primaryLanguage(input.language),
          since: input.since,
          limit: input.limit,
          now: now
        )
      )
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
    if let name = HTTPField.Name("X-Wire-Corpus-Contract") { headers[name] = "3" }
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

  private static func validActorHash(_ value: String) -> Bool {
    guard value.utf8.count == 67, value.hasPrefix("h1:") else { return false }
    return value.dropFirst(3).utf8.allSatisfy { byte in
      (48...57).contains(byte) || (97...102).contains(byte)
    }
  }
}
