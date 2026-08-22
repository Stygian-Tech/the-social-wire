import Foundation

public protocol WireFeedStore: Sendable {
  func getFeed(
    cursor: String?,
    limit: Int,
    language: String?,
    viewerDid: String?,
    now: Date
  ) async throws -> WirePage

  func getEdition(
    language: String?,
    viewerDid: String?,
    now: Date
  ) async throws -> WireEdition

  func getItem(itemId: String, viewerDid: String?) async throws -> WireItemDetail?

  func getCatalog(now: Date) async throws -> WireFeedCatalog
}
