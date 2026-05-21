import Foundation
import GatewayCore
import Hummingbird

struct DiscoveryRoutes {
  let discoveryService: DiscoveryService

  func register(on group: RouterGroup<AppRequestContext>) {
    // POST /discovery/refresh
    group.post("/discovery/refresh") { request, context in
      guard let auth = context.authContext else {
        throw HTTPError(.unauthorized)
      }
      await discoveryService.startRefresh(for: auth.did)
      return Response(
        status: .accepted,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: .init(string: """
          {"status":"accepted","message":"Discovery refresh started. Poll GET /discovery/\(auth.did) for results."}
          """))
      )
    }

    // GET /discovery/:userDid
    group.get("/discovery/:userDid") { request, context in
      guard let auth = context.authContext else {
        throw HTTPError(.unauthorized)
      }
      let userDid = try context.parameters.require("userDid", as: String.self)

      // Users may only query their own discovery results
      guard auth.did == userDid else {
        throw HTTPError(.forbidden, message: "You may only query your own discovery results")
      }

      let result = try await discoveryService.cachedPublications(for: userDid)
      return result
    }
  }
}
