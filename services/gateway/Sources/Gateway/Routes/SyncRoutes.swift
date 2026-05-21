import Foundation
import GatewayCore
import HTTPTypes
import GatewayCore
import Hummingbird

struct SyncRoutes {
  let preferenceService: PreferenceSyncService

  func register(on group: RouterGroup<GatewayRequestContext>) {

    group.get("/v1/sync/preferences") { request, context async throws -> Response in
      guard let auth = context.authContext else {
        throw HTTPError(.unauthorized, message: "Missing auth context")
      }

      let ifNoneMatchHeader = SyncRoutes.ifNoneMatch(from: request)
      return try await preferenceService.preferencesResponse(
        auth: auth,
        ifNoneMatch: ifNoneMatchHeader
      )
    }

    group.get("/v1/pds/cache/record") { request, context async throws -> Response in
      guard let auth = context.authContext else {
        throw HTTPError(.unauthorized)
      }

      guard
        let collection = request.uri.queryParameters.get("collection"),
        let rkey = request.uri.queryParameters.get("rkey")
      else {
        throw HTTPError(.badRequest, message: "Query requires `collection` and `rkey`")
      }

      return try await preferenceService.genericCachedRecordGET(
        auth: auth,
        collection: collection,
        rkey: rkey,
        ifNoneMatch: SyncRoutes.ifNoneMatch(from: request)
      )
    }
  }

  private static func ifNoneMatch(from request: Request) -> String? {
    let candidates = ["If-None-Match", "if-none-match"]
    for cand in candidates {
      guard let name = HTTPField.Name(cand) else { continue }
      if let probe = request.headers[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
         !probe.isEmpty
      {
        return probe
      }
    }
    return nil
  }
}
