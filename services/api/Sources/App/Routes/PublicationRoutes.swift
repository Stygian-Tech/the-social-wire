import Foundation
import Hummingbird

struct PublicationRoutes {
  let projectionService: PublicationProjectionService
  let resolveService: PublicationResolveService

  func register(on group: RouterGroup<AppRequestContext>) {
    group.get("/v1/publications/sidebar") { _, context async throws -> PublicationSidebarResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      return try await projectionService.sidebar(auth: auth)
    }

    group.post("/v1/publications/refresh") { _, context async throws -> PublicationRefreshAcceptedResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      _ = try await projectionService.sidebar(auth: auth)
      return PublicationRefreshAcceptedResponse(status: "ok", refreshedAt: Date())
    }

    group.post("/v1/publications/resolve") { request, context async throws -> ResolveAddPublicationResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: ResolveAddPublicationRequest.self, context: context)
      return await resolveService.resolve(input: body.input, auth: auth)
    }
  }
}
