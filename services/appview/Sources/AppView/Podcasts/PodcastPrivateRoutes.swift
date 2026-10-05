import GatewayCore
import Hummingbird

struct PodcastPrivateRoutes {
  let service: PodcastService
  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.post("/v1/podcasts/private/resolve") { request, context async throws -> PodcastResolveResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: PodcastResolveRequest.self, context: context)
      return try await service.resolvePrivate(viewer: auth.did, raw: body.url)
    }
    group.post("/v1/podcasts/private/refresh") { request, context async throws -> PodcastResolveResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: PodcastPrivateRefreshRequest.self, context: context)
      return try await service.refreshPrivate(viewer: auth.did, showID: body.showId)
    }
    group.delete("/v1/podcasts/private/subscriptions") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      guard let id = request.uri.queryParameters.get("showId"),
        try await service.store.removePrivateSubscription(viewer: auth.did, showID: id)
      else { throw HTTPError(.notFound) }
      return PodcastJSON.response("{}")
    }
  }
}
