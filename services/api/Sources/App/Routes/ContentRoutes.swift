import Foundation
import GatewayCore
import Hummingbird

struct ContentRoutes {
  let contentService: ContentService

  func register(on group: RouterGroup<AppRequestContext>) {
    // GET /publications/:pubId/entries?cursor=&limit=
    group.get("/publications/:pubId/entries") { request, context in
      guard context.authContext != nil else {
        throw HTTPError(.unauthorized)
      }

      let pubId = try context.parameters.require("pubId", as: String.self)
      let cursor = request.uri.queryParameters.get("cursor")
      let limit = request.uri.queryParameters.get("limit").flatMap(Int.init) ?? 50
      let clampedLimit = max(1, min(limit, 100))

      return try await contentService.entries(for: pubId, cursor: cursor, limit: clampedLimit)
    }

    // GET /entries/:entryId
    group.get("/entries/:entryId") { request, context in
      guard context.authContext != nil else {
        throw HTTPError(.unauthorized)
      }

      let entryId = try context.parameters.require("entryId", as: String.self)
      return try await contentService.entry(id: entryId)
    }
  }
}
