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
      guard let auth = context.authContext else {
        throw Self.feedError(.unauthorized, message: "Authentication is required.", requestId: context.requestId)
      }
      guard let kindRaw = request.uri.queryParameters.get("kind"),
            let kind = AggregateFeedKind(rawValue: kindRaw)
      else {
        throw Self.invalidRequest("Query requires a valid `kind`", requestId: context.requestId)
      }
      let id = request.uri.queryParameters.get("id")
      if kind.requiresId, id?.isEmpty != false {
        throw Self.invalidRequest("Query requires `id` for this feed kind", requestId: context.requestId)
      }
      let filterRaw = request.uri.queryParameters.get("filter") ?? "all"
      guard let filter = EntryListFilter(rawValue: filterRaw) else {
        throw Self.invalidRequest("Invalid `filter`", requestId: context.requestId)
      }
      let cursor = try Self.validatedCursor(
        request.uri.queryParameters.get("cursor"),
        requestId: context.requestId
      )
      let limit = try Self.validatedInteger(
        request.uri.queryParameters.get("limit"),
        name: "limit",
        defaultValue: 50,
        range: 1...100,
        requestId: context.requestId
      )
      return try await AppViewFeedExecution.run(requestId: context.requestId) {
        let sidebar = try await projectionService.aggregateFeedSidebar(auth: auth)
        guard let publications = Self.publications(for: kind, id: id, sidebar: sidebar) else {
          throw HTTPError(.notFound, message: "Feed is not available to this viewer")
        }
        return try await readService.listFeed(
          auth: auth,
          publications: publications,
          filter: filter,
          cursor: cursor,
          limit: limit
        )
      }
    }

    group.get("/v1/appview/entries") { request, context async throws -> AppViewEntryListResponse in
      guard let auth = context.authContext else {
        throw Self.feedError(.unauthorized, message: "Authentication is required.", requestId: context.requestId)
      }
      guard let authorDid = request.uri.queryParameters.get("authorDid") else {
        throw Self.invalidRequest("Query requires `authorDid`", requestId: context.requestId)
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
        throw Self.invalidRequest("Invalid `filter`", requestId: context.requestId)
      }
      let cursor = try Self.validatedCursor(
        request.uri.queryParameters.get("cursor"),
        requestId: context.requestId
      )
      let limit = try Self.validatedInteger(
        request.uri.queryParameters.get("limit"),
        name: "limit",
        defaultValue: 50,
        range: 1...100,
        requestId: context.requestId
      )
      let maxEntries = try Self.validatedOptionalInteger(
        request.uri.queryParameters.get("maxEntries"),
        name: "maxEntries",
        range: 1...ThinAppViewEntryPagination.maxAggregateEntries,
        requestId: context.requestId
      )
      return try await AppViewFeedExecution.run(requestId: context.requestId) {
        if let maxEntries {
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

  static func validatedCursor(_ raw: String?, requestId: String) throws -> String? {
    guard let raw else { return nil }
    guard !raw.isEmpty, ThinAppViewCursor.decode(raw) != nil else {
      throw invalidRequest("Invalid `cursor`", requestId: requestId)
    }
    return raw
  }

  static func validatedInteger(
    _ raw: String?,
    name: String,
    defaultValue: Int,
    range: ClosedRange<Int>,
    requestId: String
  ) throws -> Int {
    guard let raw else { return defaultValue }
    guard let value = Int(raw), range.contains(value) else {
      throw invalidRequest("Invalid `\(name)`", requestId: requestId)
    }
    return value
  }

  static func validatedOptionalInteger(
    _ raw: String?,
    name: String,
    range: ClosedRange<Int>,
    requestId: String
  ) throws -> Int? {
    guard let raw else { return nil }
    guard let value = Int(raw), range.contains(value) else {
      throw invalidRequest("Invalid `\(name)`", requestId: requestId)
    }
    return value
  }

  private static func invalidRequest(_ message: String, requestId: String) -> AppViewFeedError {
    feedError(.badRequest, message: message, requestId: requestId)
  }

  private static func feedError(
    _ status: HTTPResponse.Status,
    message: String,
    requestId: String
  ) -> AppViewFeedError {
    AppViewFeedError(
      status: status,
      code: status == .unauthorized ? "unauthorized" : "invalid_request",
      message: message,
      requestId: requestId,
      retryable: false
    )
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
