import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import NIOCore
import OperationsCore
import WireCore

struct WireDiscoveryRoutes {
  let store: any WireFeedStore
  let moderation: WireViewerModerationService
  let telemetry: OperationsTelemetryBuffer?

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/xrpc/app.thesocialwire.discovery.getWire") {
      request, context async throws -> Response in
      try await moderation.requireSnapshot(
        request: request,
        auth: context.authContext,
        now: Date()
      )
      let limit = try Self.limit(request.uri.queryParameters.get("limit"))
      let page = try await store.getFeed(
        cursor: request.uri.queryParameters.get("cursor"),
        limit: limit,
        language: request.uri.queryParameters.get("lang"),
        viewerDid: Self.viewerDID(context),
        now: Date()
      )
      return try Self.response(
        page,
        etag: "\"wire-\(page.generationID)-\(page.cursor ?? "end")\"",
        ifNoneMatch: request.headers[.ifNoneMatch],
        authenticated: Self.viewerDID(context) != nil,
        generationID: page.generationID,
        source: page.source.rawValue
      )
    }

    group.get("/xrpc/app.thesocialwire.discovery.getWireEdition") {
      request, context async throws -> Response in
      let startedAt = Date()
      try await moderation.requireSnapshot(
        request: request,
        auth: context.authContext,
        now: Date()
      )
      let edition = try await store.getEdition(
        language: request.uri.queryParameters.get("lang"),
        viewerDid: Self.viewerDID(context),
        now: Date()
      )
      await recordEditionMetrics(
        edition,
        latencyMilliseconds: Date().timeIntervalSince(startedAt) * 1_000,
        authenticated: Self.viewerDID(context) != nil
      )
      return try Self.response(
        WireEditionResponse(edition: edition),
        etag: "\"wire-edition-\(edition.generationID)\"",
        ifNoneMatch: request.headers[.ifNoneMatch],
        authenticated: Self.viewerDID(context) != nil,
        generationID: edition.generationID,
        source: edition.source.rawValue
      )
    }

    group.get("/xrpc/app.thesocialwire.discovery.getWireItem") {
      request, context async throws -> Response in
      try await moderation.requireSnapshot(
        request: request,
        auth: context.authContext,
        now: Date()
      )
      guard let itemID = request.uri.queryParameters.get("itemId"),
        !itemID.isEmpty, itemID.utf8.count <= 128
      else {
        throw WireServingError.invalidCursor
      }
      guard let detail = try await store.getItem(
        itemId: itemID,
        viewerDid: Self.viewerDID(context)
      ) else {
        throw WireServingError.itemNotFound
      }
      return try Self.response(
        detail,
        etag: "\"wire-item-\(detail.item.itemID)\"",
        ifNoneMatch: request.headers[.ifNoneMatch],
        authenticated: Self.viewerDID(context) != nil
      )
    }

    group.get("/xrpc/app.thesocialwire.discovery.getFeedCatalog") {
      request, context async throws -> Response in
      let catalog = try await store.getCatalog(now: Date())
      return try Self.response(
        catalog,
        etag: "\"wire-catalog-\(catalog.latestGenerationID ?? "none")-\(catalog.enabled)\"",
        ifNoneMatch: request.headers[.ifNoneMatch],
        authenticated: Self.viewerDID(context) != nil,
        generationID: catalog.latestGenerationID
      )
    }
  }

  private func recordEditionMetrics(
    _ edition: WireEdition,
    latencyMilliseconds: Double,
    authenticated: Bool
  ) async {
    guard let telemetry else { return }
    let base = [
      "algorithm": edition.algorithmVersion,
      "source": edition.source.rawValue,
      "degraded": String(edition.degraded),
      "auth": authenticated ? "viewer" : "public",
    ]
    _ = await telemetry.enqueue(.metric(OperationsMetricSample(
      name: "wire.edition.endpoint.latency_ms",
      value: latencyMilliseconds,
      dimensions: base
    )))
    let fills: [(String, Int, Int)] = [
      ("top_stories", edition.leadStories.count, WireEditionAssembler.maximumLeadStories),
      ("publication_spotlights", edition.publicationPanels.count, WireEditionAssembler.maximumPublicationPanels),
      ("people", edition.talkedAboutAccounts.count, WireEditionAssembler.maximumTalkedAboutAccounts),
      ("trending", edition.trendingStories.count, WireEditionAssembler.maximumTrendingStories),
    ]
    for (section, count, target) in fills {
      var dimensions = base
      dimensions["section"] = section
      _ = await telemetry.enqueue(.metric(OperationsMetricSample(
        name: "wire.edition.section.fill",
        value: Double(count),
        dimensions: dimensions
      )))
      _ = await telemetry.enqueue(.metric(OperationsMetricSample(
        name: "wire.edition.section.underfill",
        value: Double(max(0, target - count)),
        dimensions: dimensions
      )))
    }
    let panelStories = edition.publicationPanels.map(\.stories.count)
    let concentration = panelStories.reduce(0, +) == 0
      ? 0
      : Double(panelStories.max() ?? 0) / Double(panelStories.reduce(0, +))
    _ = await telemetry.enqueue(.metric(OperationsMetricSample(
      name: "wire.edition.publication.concentration",
      value: concentration,
      dimensions: base
    )))
  }

  private static func viewerDID(_ context: GatewayRequestContext) -> String? {
    guard let did = context.authContext?.did,
      did != GatewayInternalTrustAuthMiddleware.anonymousDiscoveryDID
    else { return nil }
    return did
  }

  private static func limit(_ raw: String?) throws -> Int {
    guard let raw else { return 30 }
    guard let value = Int(raw), (1...50).contains(value) else {
      throw WireServingError.invalidCursor
    }
    return value
  }

  static func response<Value: Encodable>(
    _ value: Value,
    etag: String,
    ifNoneMatch: String?,
    authenticated: Bool,
    generationID: String? = nil,
    source: String? = nil
  ) throws -> Response {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[.eTag] = etag
    headers[.vary] = "Authorization, Accept-Language"
    if authenticated {
      headers[.cacheControl] = "private, max-age=0"
    } else {
      headers[.cacheControl] = "public, max-age=60, stale-while-revalidate=300"
    }
    if let generationID, let name = HTTPField.Name("X-Wire-Generation") {
      headers[name] = generationID
    }
    if let source, let name = HTTPField.Name("X-Wire-Source") {
      headers[name] = source
    }
    if !authenticated, ifNoneMatch == etag {
      return Response(status: .notModified, headers: headers)
    }
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: data)))
  }
}
