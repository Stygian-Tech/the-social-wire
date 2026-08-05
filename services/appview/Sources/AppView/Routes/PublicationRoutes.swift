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

    // Returns the priority tier and pushes full follow-graph discovery into the background. The
    // synchronous `.full` rebuild this replaced walked every followed author's PDS on the request
    // path and routinely exceeded the Gateway's 60s proxy timeout.
    //
    // The response therefore carries folder sections without their publications; clients merge it
    // into their existing projection and let the bootstrap stream fill the folder tier.
    group.post("/v1/publications/refresh") { _, context async throws -> PublicationSidebarResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      await projectionService.invalidateViewerCaches(viewerDid: auth.did)
      let response = try await projectionService.refreshPrioritySidebar(auth: auth)
      Task { await projectionService.refreshFullDiscoveryAndPersist(auth: auth) }
      return response
    }

    group.post("/v1/publications/resolve") { request, context async throws -> ResolveAddPublicationResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: ResolveAddPublicationRequest.self, context: context)
      return await resolveService.resolve(input: body.input, auth: auth)
    }
  }
}
