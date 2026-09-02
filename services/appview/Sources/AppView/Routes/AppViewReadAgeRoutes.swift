import Foundation
import GatewayCore
import Hummingbird

struct AppViewReadAgeRoutes {
  let readService: ThinAppViewReadService
  let projectionService: PublicationProjectionService

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/xrpc/app.thesocialwire.appview.getReadAgeOptions") { request, context async throws -> ReadAgeOptionsResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let now = Date()
      let scope = ScopedMarkAllReadScope(
        kind: request.uri.queryParameters.get("kind") ?? "",
        publicationId: request.uri.queryParameters.get("publicationId"),
        folderRkey: request.uri.queryParameters.get("folderRkey")
      )
      try Self.validate(scope: scope)
      guard let timeZone = request.uri.queryParameters.get("timeZone") else {
        throw HTTPError(.badRequest, message: "timeZone is required")
      }
      _ = try ReadAgeCalendar.calendar(timeZone: timeZone)
      let rows = try await rows(for: scope, auth: auth)
      return try await readService.readAgeOptions(
        auth: auth, rows: rows, timeZone: timeZone, now: now
      )
    }

    group.post("/xrpc/app.thesocialwire.appview.markReadBefore") { request, context async throws -> MarkReadBeforeResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let now = Date()
      let body = try await request.decode(as: MarkReadBeforeRequest.self, context: context)
      try Self.validate(scope: body.scope)
      _ = try ReadAgeCalendar.cutoff(body.before, now: now)
      let rows = try await rows(for: body.scope, auth: auth)
      return try await readService.markReadBefore(
        auth: auth, rows: rows, before: body.before, now: now
      )
    }
  }

  static func validate(scope: ScopedMarkAllReadScope) throws {
    switch scope.kind {
    case "publication":
      guard let id = scope.publicationId, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw HTTPError(.badRequest, message: "publication scope requires publicationId")
      }
    case "folder":
      guard let id = scope.folderRkey, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw HTTPError(.badRequest, message: "folder scope requires folderRkey")
      }
    case "subscribed", "following": break
    default: throw HTTPError(.badRequest, message: "Unsupported read scope")
    }
  }

  private func rows(for scope: ScopedMarkAllReadScope, auth: AuthContext) async throws -> [SidebarPublicationRow] {
    let sidebar: PublicationSidebarResponse
    if let cached = await projectionService.cachedSidebarResponse(viewerDid: auth.did) {
      sidebar = cached
    } else {
      sidebar = try await projectionService.sidebar(auth: auth)
    }
    return AppViewExtendedRoutes.rows(for: scope, sidebar: sidebar)
  }
}
