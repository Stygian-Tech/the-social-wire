import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import NIOCore

struct CircleDiscoveryRoutes {
  let service: CircleDiscoveryService

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/xrpc/app.thesocialwire.discovery.getCircleCatalog") {
      _, context async throws -> Response in
      _ = try Self.auth(context)
      return try Self.response(await service.catalog(now: Date()))
    }
    group.get("/xrpc/app.thesocialwire.discovery.getCircleEdition") {
      request, context async throws -> Response in
      let auth = try Self.auth(context)
      let language = Self.language(request.uri.queryParameters.get("lang"))
      return try Self.response(
        await service.edition(
          request: request,
          auth: auth,
          language: language,
          cursor: request.uri.queryParameters.get("cursor"),
          now: Date()
        )
      )
    }
    group.post("/xrpc/app.thesocialwire.discovery.setCircleItemHidden") {
      request, context async throws -> Response in
      let auth = try Self.auth(context)
      let input = try await request.decode(as: CircleHiddenItemRequest.self, context: context)
      return try Self.response(
        await service.setHidden(
          viewerDID: auth.did,
          storyID: input.storyID,
          hidden: input.hidden,
          now: Date()
        )
      )
    }
  }

  private static func auth(_ context: GatewayRequestContext) throws -> AuthContext {
    guard let auth = context.authContext,
      auth.did != GatewayInternalTrustAuthMiddleware.anonymousDiscoveryDID
    else { throw HTTPError(.unauthorized) }
    return auth
  }

  private static func language(_ raw: String?) -> String {
    guard let raw else { return "und" }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let primary = normalized.split(separator: "-").first,
      primary.count >= 2, primary.count <= 8,
      primary.allSatisfy({ $0.isASCII && $0.isLetter })
    else { return "und" }
    return String(primary)
  }

  private static func response<Value: Encodable>(_ value: Value) throws -> Response {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[.cacheControl] = "private, no-store"
    headers[.vary] = "Authorization, Accept-Language"
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: data)))
  }
}
