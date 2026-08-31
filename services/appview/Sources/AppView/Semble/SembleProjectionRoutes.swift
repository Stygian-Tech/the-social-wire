import GatewayCore
import Hummingbird

struct SembleProjectionRoutes {
  let service: SembleProjectionService

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/v1/semble/collections") { request, context async throws -> SembleCollectionsResponseDTO in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      return try await service.collections(
        viewerDid: auth.did,
        cursor: request.uri.queryParameters.get("cursor"),
        limit: try Self.limit(request.uri.queryParameters.get("limit"))
      )
    }

    group.get("/v1/semble/collection") { request, context async throws -> SembleCollectionPageResponseDTO in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      guard let collectionUri = request.uri.queryParameters.get("collectionUri"), !collectionUri.isEmpty else {
        throw SembleProjectionError.invalid("Query requires `collectionUri`.")
      }
      return try await service.collection(
        viewerDid: auth.did,
        collectionUri: collectionUri,
        cursor: request.uri.queryParameters.get("cursor"),
        limit: try Self.limit(request.uri.queryParameters.get("limit"))
      )
    }

    group.get("/v1/semble/connections") { request, context async throws -> SembleConnectionsResponseDTO in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      guard let url = request.uri.queryParameters.get("url"), !url.isEmpty else {
        throw SembleProjectionError.invalid("Query requires `url`.")
      }
      return try await service.connections(
        viewerDid: auth.did,
        url: url,
        cursor: request.uri.queryParameters.get("cursor"),
        limit: try Self.limit(request.uri.queryParameters.get("limit"))
      )
    }
  }

  static func limit(_ raw: String?) throws -> Int {
    guard let raw else { return 50 }
    guard let value = Int(raw), (1...100).contains(value) else {
      throw SembleProjectionError.invalid("`limit` must be between 1 and 100.")
    }
    return value
  }
}
