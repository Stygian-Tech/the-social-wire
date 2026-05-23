import Foundation
import GatewayCore
import Hummingbird
import ThinAppViewCore

struct AppViewExtendedRoutes {
  let readService: ThinAppViewReadService
  let projectionService: PublicationProjectionService
  let repo: ATProtoAuthenticatedRepoClient

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/v1/appview/entry") { request, context async throws -> AppViewEntryDetailResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      guard let entryId = request.uri.queryParameters.get("entryId") else {
        throw HTTPError(.badRequest, message: "Query requires `entryId`")
      }
      return try await readService.entryDetail(auth: auth, entryId: entryId)
    }

    group.get("/v1/appview/unread-counts") { request, context async throws -> AppViewUnreadCountsByPublicationResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      if let rawIds = request.uri.queryParameters.get("publicationIds") {
        let publicationIds = Self.splitQueryList(rawIds)
        return try await readService.unreadCountsByPublicationIds(
          auth: auth,
          publicationIds: publicationIds,
          projectionService: projectionService
        )
      }
      let authorDid = request.uri.queryParameters.get("authorDid")
      let publicationAtUri = request.uri.queryParameters.get("publicationAtUri")
      let scopeUris = Self.splitQueryList(request.uri.queryParameters.get("publicationScopeAtUris"))
      let siteUrls = Self.splitQueryList(request.uri.queryParameters.get("publicationSiteUrls"))
      let scoped = try await readService.unreadCounts(
        auth: auth,
        authorDid: authorDid,
        publicationAtUri: publicationAtUri,
        publicationScopeAtUris: scopeUris,
        publicationSiteUrls: siteUrls
      )
      var map: [String: Int] = [:]
      for row in scoped.counts {
        map[row.scopeKey] = row.unreadCount
      }
      return AppViewUnreadCountsByPublicationResponse(counts: map)
    }

    group.post("/v1/appview/mark-all-read") { request, context async throws -> MarkAllReadResponse in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: ScopedMarkAllReadRequest.self, context: context)
      let sidebar = try await projectionService.sidebar(auth: auth)
      let rows = Self.rows(for: body.scope, sidebar: sidebar)
      let now = ISO8601DateFormatter().string(from: Date())
      var marked = 0
      for row in rows {
        let unread = try await readService.listEntries(
          auth: auth,
          authorDid: row.appViewScope.authorDid,
          publicationAtUri: row.appViewScope.publicationAtUri,
          publicationScopeAtUris: row.appViewScope.publicationScopeAtUris,
          publicationSiteUrls: row.appViewScope.publicationSiteUrls,
          filter: .unread,
          cursor: nil,
          limit: 500
        )
        for entry in unread.entries {
          try await repo.putRecord(
            auth: auth,
            collection: PublicationLexicons.entryReadState,
            rkey: DeterministicKeys.entryReadStateRKey(subjectURI: entry.entryId),
            record: [
              "$type": PublicationLexicons.entryReadState,
              "subjectUri": entry.entryId,
              "readAt": now,
              "updatedAt": now,
            ]
          )
          try await readService.upsertReadMark(auth: auth, subjectUri: entry.entryId, readAt: Date())
          marked += 1
        }
      }
      await projectionService.invalidateViewerCaches(viewerDid: auth.did)
      return MarkAllReadResponse(marked: marked)
    }
  }

  private static func splitQueryList(_ raw: String?) -> [String] {
    guard let raw else { return [] }
    return raw
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func rows(
    for scope: ScopedMarkAllReadScope,
    sidebar: PublicationSidebarResponse
  ) -> [SidebarPublicationRow] {
    switch scope.kind {
    case "publication":
      guard let publicationId = scope.publicationId else { return [] }
      return sidebar.allPublicationRows.filter { $0.publicationId == publicationId }
    case "folder":
      guard let folderRkey = scope.folderRkey else { return [] }
      return sidebar.folderSections
        .first(where: { $0.folderRkey == folderRkey })?
        .publications ?? []
    case "subscribed":
      return sidebar.subscribedUnfoldered + sidebar.folderSections.flatMap(\.publications)
    case "following":
      return sidebar.followingTabPublications
    default:
      return []
    }
  }
}

public struct AppViewEntryDetailResponse: Codable, Sendable, ResponseEncodable {
  public let entryId: String
  public let title: String
  public let summary: String?
  public let publishedAt: Date
  public let thumbnailUrl: String?
  public let isRead: Bool
  public let contentHtml: String?

  public init(
    entryId: String,
    title: String,
    summary: String? = nil,
    publishedAt: Date,
    thumbnailUrl: String? = nil,
    isRead: Bool,
    contentHtml: String? = nil
  ) {
    self.entryId = entryId
    self.title = title
    self.summary = summary
    self.publishedAt = publishedAt
    self.thumbnailUrl = thumbnailUrl
    self.isRead = isRead
    self.contentHtml = contentHtml
  }
}

public struct AppViewUnreadCountRow: Codable, Sendable {
  public let scopeKey: String
  public let unreadCount: Int
}

public struct AppViewUnreadCountsResponse: Codable, Sendable, ResponseEncodable {
  public let counts: [AppViewUnreadCountRow]
}

public struct AppViewUnreadCountsByPublicationResponse: Codable, Sendable, ResponseEncodable {
  public let counts: [String: Int]
}

struct ScopedMarkAllReadRequest: Codable, Sendable {
  let scope: ScopedMarkAllReadScope
}

struct ScopedMarkAllReadScope: Codable, Sendable {
  let kind: String
  let publicationId: String?
  let folderRkey: String?
}

struct MarkAllReadResponse: Codable, Sendable, ResponseEncodable {
  let marked: Int
}
