import Foundation
import GatewayCore
import Hummingbird
import ThinAppViewCore

struct AppViewExtendedRoutes {
  let readService: ThinAppViewReadService
  let projectionService: PublicationProjectionService

  func register(on group: RouterGroup<GatewayRequestContext>) {
    for path in ["/v1/appview/entry", "/xrpc/app.thesocialwire.appview.getEntry"] as [RouterPath] {
      group.get(path) { request, context async throws -> AppViewEntryDetailResponse in
        guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
        guard let entryId = request.uri.queryParameters.get("entryId") else {
          throw HTTPError(.badRequest, message: "Query requires `entryId`")
        }
        return try await readService.entryDetail(auth: auth, entryId: entryId)
      }
    }

    for path in ["/v1/appview/unread-counts", "/xrpc/app.thesocialwire.appview.getUnreadCounts"]
      as [RouterPath]
    {
      group.get(path) { request, context async throws -> AppViewUnreadCountsByPublicationResponse in
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
        let scopeUris = Self.splitQueryList(
          request.uri.queryParameters.get("publicationScopeAtUris"))
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
    }

    for path in ["/v1/appview/mark-all-read", "/xrpc/app.thesocialwire.appview.markAllRead"]
      as [RouterPath]
    {
      group.post(path) { request, context async throws -> MarkAllReadResponse in
        guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
        let body = try await request.decode(as: ScopedMarkAllReadRequest.self, context: context)
        let sidebar: PublicationSidebarResponse
        if let cached = await projectionService.cachedSidebarResponse(viewerDid: auth.did) {
          sidebar = cached
        } else {
          // No durable projection yet for this viewer (e.g. first request ever) — only then
          // pay for a live discovery pass across every followed author's PDS.
          sidebar = try await projectionService.sidebar(auth: auth)
        }
        let rows = Self.rows(for: body.scope, sidebar: sidebar)
        let result:
          (
            counters: [AppViewUnreadCounter],
            boundaries: [ReadWatermarkBoundary],
            confirmedAt: Date,
            marked: Int
          )
        do {
          result = try await readService.markAllRead(auth: auth, rows: rows)
        } catch {
          context.logger.error(
            "mark-all-read failed",
            metadata: [
              "did": .string(auth.did),
              "scopeKind": .string(body.scope.kind),
              "rowCount": .stringConvertible(rows.count),
              "error": .string("\(error)"),
            ]
          )
          throw error
        }
        return MarkAllReadResponse(
          marked: result.marked,
          confirmedAt: result.confirmedAt,
          boundaries: result.boundaries,
          unreadCounts: Dictionary(
            uniqueKeysWithValues: result.counters.map { ($0.publicationId, $0.unreadCount) }
          )
        )
      }
    }
  }

  private static func splitQueryList(_ raw: String?) -> [String] {
    guard let raw else { return [] }
    return
      raw
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
  public let originalUrl: String?

  public init(
    entryId: String,
    title: String,
    summary: String? = nil,
    publishedAt: Date,
    thumbnailUrl: String? = nil,
    isRead: Bool,
    contentHtml: String? = nil,
    originalUrl: String? = nil
  ) {
    self.entryId = entryId
    self.title = title
    self.summary = summary
    self.publishedAt = publishedAt
    self.thumbnailUrl = thumbnailUrl
    self.isRead = isRead
    self.contentHtml = contentHtml
    self.originalUrl = originalUrl
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
  public let generation: Int64?
  public let accuracy: String?
  public let countedAt: Date?

  public init(
    counts: [String: Int],
    generation: Int64? = nil,
    accuracy: String? = nil,
    countedAt: Date? = nil
  ) {
    self.counts = counts
    self.generation = generation
    self.accuracy = accuracy
    self.countedAt = countedAt
  }
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
  let confirmedAt: Date
  let boundaries: [ReadWatermarkBoundary]
  let unreadCounts: [String: Int]
}
