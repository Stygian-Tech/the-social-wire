import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import ThinAppViewCore

struct ThinAppViewRoutes {
  let readService: ThinAppViewReadService
  let enrollService: ThinAppViewEnrollService
  let projectionService: PublicationProjectionService

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/v1/appview/feed") { request, context async throws -> Response in
      guard let auth = context.authContext else {
        throw Self.feedError(.unauthorized, message: "Authentication is required.", requestId: context.requestId)
      }
      guard let kindRaw = request.uri.queryParameters.get("kind"),
            let kind = AppViewFeedKind(rawValue: kindRaw)
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
      let selector = AppViewFeedSelector(kind: kind, id: id)
      return try await AppViewFeedExecution.run(requestId: context.requestId) {
        let startedAt = Date()
        var page = try await readService.listFeed(
          auth: auth,
          selector: selector,
          filter: filter,
          cursor: cursor,
          limit: limit
        )
        if page == nil {
          let repaired = await projectionService.rebuildFeedProjectionFromCachedSidebar(
            viewerDid: auth.did
          )
          if repaired {
            page = try await readService.listFeed(
              auth: auth,
              selector: selector,
              filter: filter,
              cursor: cursor,
              limit: limit
            )
          }
          if page == nil {
            let hasProjection: Bool
            if repaired {
              hasProjection = true
            } else {
              hasProjection = try await readService.hasFeedProjection(auth: auth)
            }
            if hasProjection {
              throw AppViewFeedError(
                status: .notFound,
                code: "feed_unavailable",
                message: "Feed is not available to this viewer.",
                requestId: context.requestId,
                retryable: false
              )
            }
            throw AppViewFeedError(
              status: .serviceUnavailable,
              code: "feed_projection_warming",
              message: "The viewer feed projection is warming.",
              requestId: context.requestId,
              retryable: true
            )
          }
        }
        guard let page else {
          throw AppViewFeedError(
            status: .serviceUnavailable,
            code: "feed_projection_warming",
            message: "The viewer feed projection is warming.",
            requestId: context.requestId,
            retryable: true
          )
        }
        return try Self.feedResponse(
          page: page,
          durationMilliseconds: Date().timeIntervalSince(startedAt) * 1_000
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

  private static func feedResponse(
    page: AppViewFeedPage,
    durationMilliseconds: Double
  ) throws -> Response {
    let data = try JSONEncoder().encode(page.response)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-AppView-Feed-Source")!] = "materialized_projection"
    headers[HTTPField.Name("X-AppView-Membership-Updated-At")!] =
      page.membershipUpdatedAt.ISO8601Format()
    headers[HTTPField.Name("Server-Timing")!] = String(
      format: "db;dur=%.1f, appview_feed;dur=%.1f",
      page.databaseDurationMilliseconds,
      durationMilliseconds
    )
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: .init(data: data)))
  }
}

extension AppViewEntryListResponse: @retroactive ResponseEncodable {}
