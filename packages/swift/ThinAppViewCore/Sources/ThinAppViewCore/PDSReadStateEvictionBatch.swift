public struct PDSReadStateEvictionBatch: Sendable {
  public let viewerDid: String?
  public let deletedRows: Int
  public let hasMore: Bool
  public init(viewerDid: String?, deletedRows: Int, hasMore: Bool) {
    self.viewerDid = viewerDid
    self.deletedRows = deletedRows
    self.hasMore = hasMore
  }
}
