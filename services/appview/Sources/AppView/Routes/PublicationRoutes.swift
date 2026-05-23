import Foundation
import GatewayCore
import Hummingbird

struct PublicationRoutes {
  let projectionService: PublicationProjectionService
  let resolveService: PublicationResolveService

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/v1/publications/sidebar") { request, context async throws -> PublicationSidebarResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let phase = request.uri.queryParameters.get("phase")
        .flatMap(SidebarBuildPhase.init(rawValue:)) ?? .full
      return try await projectionService.sidebar(auth: auth, phase: phase)
    }

    group.post("/v1/publications/refresh") { _, context async throws -> PublicationSidebarResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      return try await projectionService.sidebar(auth: auth, phase: .full)
    }

    group.post("/v1/publications/resolve") { request, context async throws -> ResolveAddPublicationResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: ResolveAddPublicationRequest.self, context: context)
      return await resolveService.resolve(input: body.input, auth: auth)
    }
  }
}
