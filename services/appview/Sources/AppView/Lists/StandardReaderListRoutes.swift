import GatewayCore
import Hummingbird

struct StandardReaderListRoutes {
  let service: StandardReaderListsService

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/v1/lists") { _, context async throws -> StandardReaderListsResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      return try await service.lists(viewerDid: auth.did)
    }
    group.get("/v1/lists/search") { request, context async throws -> StandardReaderListsResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      guard let creator = request.uri.queryParameters.get("creator") else {
        throw HTTPError(.badRequest, message: "Query requires creator handle or DID.")
      }
      return try await service.search(creator: creator, viewerDid: auth.did)
    }
    group.post("/v1/lists/resolve") { request, context async throws -> StandardReaderListResolveResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: StandardReaderListResolveRequest.self, context: context)
      let list = try await service.resolve(input: body.input, viewerDid: auth.did)
      return StandardReaderListResolveResponse(list: list)
    }
    group.post("/v1/lists/refresh") { _, context async throws -> StandardReaderListsResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      return try await service.lists(viewerDid: auth.did, refresh: true)
    }
  }
}
