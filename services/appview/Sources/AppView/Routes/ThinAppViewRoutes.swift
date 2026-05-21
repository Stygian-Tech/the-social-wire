import Foundation
import GatewayCore
import Hummingbird
import ThinAppViewCore

struct ThinAppViewRoutes {
  let readService: ThinAppViewReadService
  let enrollService: ThinAppViewEnrollService

  func register(on group: RouterGroup<GatewayRequestContext>) {
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
      let indexed = try await enrollService.enroll(auth: auth, authorDids: body.authorDids)
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
}

extension AppViewEntryListResponse: @retroactive ResponseEncodable {}
