import AsyncHTTPClient
import Foundation
import Logging
import NIOCore

/// Indexes repo commits into `content_items` and `read_marks`.
actor ThinAppViewIndexer {
  private let store: any ThinAppViewStore
  private let config: ThinAppViewConfig
  private let logger: Logger

  init(store: any ThinAppViewStore, config: ThinAppViewConfig, logger: Logger) {
    self.store = store
    self.config = config
    self.logger = logger
  }

  func handleCommit(
    repoDid: String,
    collection: String,
    rkey: String,
    cid: String,
    recordJSON: Data,
    operation: String
  ) async throws {
    let record = (try JSONSerialization.jsonObject(with: recordJSON) as? [String: Any]) ?? [:]
    if ThinAppViewConfig.readStateCollection == collection {
      try await handleReadStateCommit(repoDid: repoDid, rkey: rkey, record: record, operation: operation)
      return
    }

    guard ThinAppViewConfig.contentCollections.contains(collection) else { return }

    let uri = RenderFieldExtractor.buildEntryUri(did: repoDid, collection: collection, rkey: rkey)
    if operation == "delete" {
      try await store.deleteContentItem(uri: uri)
      return
    }

    let render = RenderFieldExtractor.extractRenderFields(from: record)
    let createdAt = RenderFieldExtractor.createdAtDate(from: record, fallback: render)
    let now = Date()
    let item = IndexedContentItem(
      uri: uri,
      cid: cid,
      authorDid: repoDid,
      collection: collection,
      createdAt: createdAt,
      indexedAt: now,
      publicationSite: RenderFieldExtractor.publicationSiteField(from: record),
      render: render,
      expiresAt: now.addingTimeInterval(config.contentRetentionSeconds)
    )
    try await store.upsertContentItem(item)
  }

  private func handleReadStateCommit(
    repoDid: String,
    rkey: String,
    record: [String: Any],
    operation: String
  ) async throws {
    guard let subjectUri = record["subjectUri"] as? String else { return }
    if operation == "delete" {
      try await store.deleteReadMark(viewerDid: repoDid, subjectUri: subjectUri)
      return
    }

    let readAtRaw = (record["readAt"] as? String) ?? (record["updatedAt"] as? String)
    let readAt = readAtRaw.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
    try await store.upsertReadMark(viewerDid: repoDid, subjectUri: subjectUri, createdAt: readAt)
    _ = rkey
  }
}
