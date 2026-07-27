import Foundation
import GatewayCore
import Hummingbird
import ThinAppViewCore

struct ThinAppViewRoutes {
  let readService: ThinAppViewReadService
  let enrollService: ThinAppViewEnrollService
  let projectionService: PublicationProjectionService

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/v1/appview/feed") { request, context async throws -> AppViewEntryListResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      guard let kindRaw = request.uri.queryParameters.get("kind"),
            let kind = AggregateFeedKind(rawValue: kindRaw)
      else {
        throw HTTPError(.badRequest, message: "Query requires a valid `kind`")
      }
      let id = request.uri.queryParameters.get("id")
      if kind.requiresId, id?.isEmpty != false {
        throw HTTPError(.badRequest, message: "Query requires `id` for this feed kind")
      }
      let filterRaw = request.uri.queryParameters.get("filter") ?? "all"
      guard let filter = EntryListFilter(rawValue: filterRaw) else {
        throw HTTPError(.badRequest, message: "Invalid `filter`")
      }
      let sidebar = try await projectionService.sidebar(auth: auth)
      guard let publications = Self.publications(for: kind, id: id, sidebar: sidebar) else {
        throw HTTPError(.notFound, message: "Feed is not available to this viewer")
      }
      return try await readService.listFeed(
        auth: auth,
        publications: publications,
        filter: filter,
        cursor: request.uri.queryParameters.get("cursor"),
        limit: Int(request.uri.queryParameters.get("limit") ?? "50") ?? 50
      )
    }

    group.get("/v1/appview/entries") { request, context async throws -> AppViewEntryListResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      guard let authorDid = request.uri.queryParameters.get("authorDid") else {
        throw HTTPError(.badRequest, message: "Query requires `authorDid`")
      }
      let publicationAtUri = request.uri.queryParameters.get("publicationAtUri")
      let publicationScopeAtUris = Self.splitQueryList(
        request.uri.queryParameters.get("publicationScopeAtUris")
      )
      let publicationSiteUrls = Self.splitQueryList(
        request.uri.queryParameters.get("publicationSiteUrls")
      )
      let filterRaw = request.uri.queryParameters.get("filter") ?? "all"
      guard let filter = EntryListFilter(rawValue: filterRaw) else {
        throw HTTPError(.badRequest, message: "Invalid `filter`")
      }
      let cursor = request.uri.queryParameters.get("cursor")
      let limit = Int(request.uri.queryParameters.get("limit") ?? "50") ?? 50
      if let maxRaw = request.uri.queryParameters.get("maxEntries"),
         let maxEntries = Int(maxRaw)
      {
        return try await readService.listEntriesUpTo(
          auth: auth,
          authorDid: authorDid,
          publicationAtUri: publicationAtUri,
          publicationScopeAtUris: publicationScopeAtUris,
          publicationSiteUrls: publicationSiteUrls,
          filter: filter,
          maxEntries: maxEntries,
          pageLimit: limit
        )
      }

      return try await readService.listEntries(
        auth: auth,
        authorDid: authorDid,
        publicationAtUri: publicationAtUri,
        publicationScopeAtUris: publicationScopeAtUris,
        publicationSiteUrls: publicationSiteUrls,
        filter: filter,
        cursor: cursor,
        limit: limit
      )
    }

    group.post("/v1/appview/read-marks") { request, context async throws -> HTTPResponse.Status in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: AppViewReadMarkRequest.self, context: context)
      try await readService.upsertReadMark(auth: auth, subjectUri: body.subjectUri, readAt: body.readAt)
      return .ok
    }

    group.delete("/v1/appview/read-marks") { request, context async throws -> HTTPResponse.Status in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: AppViewReadMarkDeleteRequest.self, context: context)
      try await readService.deleteReadMark(auth: auth, subjectUri: body.subjectUri)
      return .ok
    }

    group.post("/v1/appview/enroll") { request, context async throws -> AppViewEnrollResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: AppViewEnrollRequest.self, context: context)
      let indexed = try await enrollService.enroll(
        auth: auth,
        authorDids: body.authorDids,
        feedUrls: body.feedUrls
      )
      await projectionService.invalidateViewerCaches(viewerDid: auth.did)
      return AppViewEnrollResponse(indexed: indexed)
    }

    group.delete("/v1/appview/privacy/purge") { request, context async throws -> HTTPResponse.Status in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      try await readService.purge(auth: auth)
      return .ok
    }
  }

  private static func splitQueryList(_ raw: String?) -> [String] {
    guard let raw else { return [] }
    return raw
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func publications(
    for kind: AggregateFeedKind,
    id: String?,
    sidebar: PublicationSidebarResponse
  ) -> [SidebarPublicationRow]? {
    let rows: [SidebarPublicationRow]
    switch kind {
    case .subscribed:
      rows =
        sidebar.myPublications
        + sidebar.subscribedUnfoldered
        + sidebar.folderSections.flatMap(\.publications)
    case .following:
      rows = sidebar.followingTabPublications
    case .folder:
      guard let id,
            let folder = sidebar.folderSections.first(where: {
              $0.folderRkey == id || $0.folderUri == id
            })
      else { return nil }
      rows = folder.publications
    case .publication:
      guard let id,
            let publication = sidebar.allPublicationRows.first(where: {
              PublicationProjectionLogic.publicationIdsMatch($0.publicationId, id)
            })
      else { return nil }
      rows = [publication]
    }

    var seen = Set<String>()
    return rows.filter { seen.insert($0.publicationId).inserted }
  }
}

private enum AggregateFeedKind: String {
  case subscribed
  case following
  case folder
  case publication

  var requiresId: Bool {
    self == .folder || self == .publication
  }
}

extension AppViewEntryListResponse: @retroactive ResponseEncodable {}
