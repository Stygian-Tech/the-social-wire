import Foundation
import GatewayCore
import Hummingbird
import Logging
import ThinAppViewCore

actor ThinAppViewReadService {
  private let store: any ThinAppViewStore
  private let logger: Logger

  init(store: any ThinAppViewStore, logger: Logger) {
    self.store = store
    self.logger = logger
  }

  func listEntries(
    auth: AuthContext,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewEntryListResponse {
    try await store.listEntries(
      viewerDid: auth.did,
      authorDid: authorDid,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls,
      filter: filter,
      cursor: cursor,
      limit: limit
    )
  }

  func upsertReadMark(auth: AuthContext, subjectUri: String, readAt: Date?) async throws {
    try await store.upsertReadMark(
      viewerDid: auth.did,
      subjectUri: subjectUri,
      createdAt: readAt ?? Date()
    )
  }

  func deleteReadMark(auth: AuthContext, subjectUri: String) async throws {
    try await store.deleteReadMark(viewerDid: auth.did, subjectUri: subjectUri)
  }

  func purge(auth: AuthContext) async throws {
    try await store.purgeReadMarks(viewerDid: auth.did)
    logger.info("Purged thin AppView read marks", metadata: ["did": .string(auth.did)])
  }

  func entryDetail(auth: AuthContext, entryId: String) async throws -> AppViewEntryDetailResponse {
    let list = try await store.listEntries(
      viewerDid: auth.did,
      authorDid: auth.did,
      publicationAtUri: nil,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
      filter: .all,
      cursor: nil,
      limit: 200
    )
    guard let item = list.entries.first(where: { $0.entryId == entryId }) else {
      throw HTTPError(.notFound, message: "Entry not found in AppView index")
    }
    let readList = try await store.listEntries(
      viewerDid: auth.did,
      authorDid: auth.did,
      publicationAtUri: nil,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
      filter: .read,
      cursor: nil,
      limit: 200
    )
    let isRead = readList.entries.contains { $0.entryId == entryId }
    return AppViewEntryDetailResponse(
      entryId: item.entryId,
      title: item.title,
      summary: item.summary,
      publishedAt: item.publishedAt,
      thumbnailUrl: item.thumbnailUrl,
      isRead: isRead,
      contentHtml: item.summary
    )
  }

  func unreadCountsByPublicationIds(
    auth: AuthContext,
    publicationIds: [String],
    projectionService: PublicationProjectionService
  ) async throws -> AppViewUnreadCountsByPublicationResponse {
    let sidebar = try await projectionService.sidebar(auth: auth)
    var counts: [String: Int] = [:]
    for publicationId in publicationIds {
      guard let row = sidebar.allPublicationRows.first(where: { $0.publicationId == publicationId }) else {
        continue
      }
      let unread = try await store.listEntries(
        viewerDid: auth.did,
        authorDid: row.appViewScope.authorDid,
        publicationAtUri: row.appViewScope.publicationAtUri,
        publicationScopeAtUris: row.appViewScope.publicationScopeAtUris,
        publicationSiteUrls: row.appViewScope.publicationSiteUrls,
        filter: .unread,
        cursor: nil,
        limit: 500
      )
      if !unread.entries.isEmpty {
        counts[publicationId] = unread.entries.count
      }
    }
    return AppViewUnreadCountsByPublicationResponse(counts: counts)
  }

  func unreadCounts(
    auth: AuthContext,
    authorDid: String?,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String]
  ) async throws -> AppViewUnreadCountsResponse {
    let did = authorDid ?? auth.did
    let unread = try await store.listEntries(
      viewerDid: auth.did,
      authorDid: did,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls,
      filter: .unread,
      cursor: nil,
      limit: 500
    )
    let key = publicationAtUri ?? did
    return AppViewUnreadCountsResponse(
      counts: [AppViewUnreadCountRow(scopeKey: key, unreadCount: unread.entries.count)]
    )
  }
}
