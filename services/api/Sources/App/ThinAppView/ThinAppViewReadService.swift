import AsyncHTTPClient
import GatewayCore
import Foundation
import Hummingbird
import Logging
import ThinAppViewCore
import NIOCore

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
}
