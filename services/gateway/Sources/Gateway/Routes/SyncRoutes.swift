import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird

struct SyncRoutes {
  let preferenceService: PreferenceSyncService
  let repo: ATProtoAuthenticatedRepoClient

  func register(on group: RouterGroup<GatewayRequestContext>) {

    for path in ["/v1/sync/preferences", "/xrpc/app.thesocialwire.sync.getPreferences"]
      as [RouterPath]
    {
      group.get(path) { request, context async throws -> Response in
        guard let auth = context.authContext else {
          throw HTTPError(.unauthorized, message: "Missing auth context")
        }

        let freshParameter = request.uri.queryParameters.get("fresh")
        let forceRefresh = freshParameter == "true" || freshParameter == "1"
        if !forceRefresh {
          _ = try await LexiconMigration.migrateLegacyLexiconsIfNeeded(repo: repo, auth: auth)
        }

        let ifNoneMatchHeader = SyncRoutes.ifNoneMatch(from: request)
        return try await preferenceService.preferencesResponse(
          auth: auth,
          ifNoneMatch: ifNoneMatchHeader,
          forceRefresh: forceRefresh
        )
      }
    }

    group.post("/v1/sync/migrate-lexicons") { _, context async throws -> LexiconMigrationResponse in
      guard let auth = context.authContext else {
        throw HTTPError(.unauthorized, message: "Missing auth context")
      }
      let summary = try await LexiconMigration.migrateLegacyLexiconsIfNeeded(repo: repo, auth: auth)
      return LexiconMigrationResponse(summary: summary)
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

public struct LexiconMigrationResponse: Codable, Sendable, ResponseEncodable {
  public let summary: LexiconMigrationSummary

  public init(summary: LexiconMigrationSummary) {
    self.summary = summary
  }
}
