import Foundation

/// Persistence for thin AppView `content_items` and `read_marks`.
public protocol ThinAppViewStore: Actor {
  func upsertContentItem(_ item: IndexedContentItem) async throws
  func deleteContentItem(uri: String) async throws

  func upsertReadMark(viewerDid: String, subjectUri: String, createdAt: Date) async throws
  func deleteReadMark(viewerDid: String, subjectUri: String) async throws
  func purgeReadMarks(viewerDid: String) async throws

  func fetchContentItem(uri: String) async throws -> AppViewEntryListItem?
  func hasReadMark(viewerDid: String, subjectUri: String) async throws -> Bool

  func listEntries(
    viewerDid: String,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewEntryListResponse

  func countUnreadEntries(
    viewerDid: String,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String]
  ) async throws -> Int

  func deleteExpiredContent(before: Date) async throws -> Int
  func deleteExpiredReadMarks(before: Date) async throws -> Int

  /// Authors with the stalest index; used by the worker proactive backfill loop.
  func listAuthorDidsForProactiveBackfill(limit: Int) async throws -> [String]

  /// Distinct RSS feed URLs (`publication_site`) for Skyreader poll refresh.
  func listRssPublicationSites(limit: Int) async throws -> [String]

  func fetchContentRender(uri: String) async throws -> ContentRenderFields?
}
