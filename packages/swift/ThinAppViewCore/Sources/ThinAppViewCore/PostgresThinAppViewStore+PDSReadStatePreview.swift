import Foundation
import ReadStateCore

extension PostgresThinAppViewStore {
  public func previewPDSReadStateBoundaries(
    viewerDid: String, boundaries: [ReadStateBoundary], subjectUris: [String]
  ) async throws -> [String] {
    guard subjectUris.count <= 1_000, boundaries.count <= 1_000 else { throw ReadStateError.sizeLimit }
    guard !subjectUris.isEmpty, !boundaries.isEmpty else { return [] }
    let operations = boundaries.enumerated().map { index, boundary in
      ReadStateOperation(actionId: "preview-\(index)", sequence: Int64(index + 1), state: .read,
        actedAt: boundary.createdAt, boundaries: [boundary])
    }
    let projection = try ReadStateProjection(operations: operations, lastSequence: Int64(operations.count))
    let ids = Array(Set(subjectUris)).sorted()
    var matched: [String] = []
    for try await row in try await pool.query(
      """
      SELECT uri, author_did, publication_site, created_at FROM content_items
      WHERE uri = ANY(\(ids)::text[]) ORDER BY uri COLLATE "C"
      """, logger: logger) {
      let item = try row.decode((String, String, String?, Date).self)
      if projection.resolve(ReadStateSubject(uri: item.0, authorDid: item.1,
        publicationSite: item.2, createdAt: item.3)).isRead { matched.append(item.0) }
    }
    return matched
  }
}
