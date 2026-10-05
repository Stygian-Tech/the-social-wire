import SportsCore
import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import NIOCore
import OperationsCore

struct SportsDiscoveryRoutes {
  let store: PostgresSportsFeedStore
  let moderation: WireViewerModerationService
  let telemetry: OperationsTelemetryBuffer?

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/xrpc/app.thesocialwire.discovery.getSports") { request, context async throws -> Response in
      let now = Date()
      try await moderation.requireSnapshot(request: request, auth: context.authContext, now: now)
      let rawLimit = request.uri.queryParameters.get("limit")
      guard rawLimit == nil || Int(rawLimit!).map({ (1...50).contains($0) }) == true else { throw WireServingError.invalidCursor }
      let region = request.uri.queryParameters.get("region")
      guard region == nil || region == "outside-us" else { throw WireServingError.invalidCursor }
      let refresh = request.uri.queryParameters.get("refreshSelections")
      guard refresh == nil || ["true", "false"].contains(refresh!) else { throw WireServingError.invalidCursor }
      let page = try await store.page(cursor: request.uri.queryParameters.get("cursor"), limit: rawLimit.flatMap(Int.init) ?? 30,
        language: request.uri.queryParameters.get("lang"), viewerDID: Self.viewer(context), refresh: refresh == "true", now: now, feed: request.uri.queryParameters.get("feed") ?? "sports", region: region)
      _ = await telemetry?.enqueue(.metric(OperationsMetricSample(name: "sports.feed.items", value: Double(page.items.count),
        dimensions: ["source": page.source.rawValue, "degraded": String(page.degraded)])))
      return try Self.response(page, generationID: page.generationId, source: page.source.rawValue)
    }
    group.get("/xrpc/app.thesocialwire.discovery.getSportsCatalog") { _, _ async throws -> Response in
      try Self.response(await store.availability(now: Date()))
    }
    group.get("/xrpc/app.thesocialwire.discovery.searchSportsEntities") { request, _ async throws -> Response in
      let query = try SportsSearchQuery.decode(request.uri.query)
      return try Self.response(SportsEntitySearchResponse(entities: await store.entities(query: query, now: Date())))
    }
    group.get("/xrpc/app.thesocialwire.discovery.getSportsEvents") { request, _ async throws -> Response in
      try Self.response(await store.events(feed: request.uri.queryParameters.get("feed") ?? "sports", now: Date(), teamIDs: SportsEventTeamFilter.decode(request.uri.queryParameters.get("teamIDs")), preferredIDs: SportsEventTeamFilter.decode(request.uri.queryParameters.get("preferredIDs")), timeZone: SportsEventTeamFilter.timeZone(request.uri.queryParameters.get("timeZone")), timeZoneName: request.uri.queryParameters.get("timeZone")))
    }

  }
  private static func viewer(_ context: GatewayRequestContext) -> String? {
    guard let did = context.authContext?.did, did != GatewayInternalTrustAuthMiddleware.anonymousDiscoveryDID else { return nil }
    return did
  }
  private static func response<T: Encodable>(_ value: T, generationID: String? = nil, source: String? = nil) throws -> Response {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    var headers = HTTPFields(); headers[.contentType] = "application/json"; headers[.cacheControl] = "private, no-store"
    if let generationID, let name = HTTPField.Name("X-Wire-Generation") { headers[name] = generationID }
    if let source, let name = HTTPField.Name("X-Wire-Source") { headers[name] = source }
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: try encoder.encode(value))))
  }
}
