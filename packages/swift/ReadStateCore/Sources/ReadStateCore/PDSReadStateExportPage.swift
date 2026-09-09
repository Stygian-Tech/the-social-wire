public struct PDSReadStateExportPage: Codable, Sendable, Equatable {
  public let legacyRevision: Int64
  public let rows: [ReadStateLegacyRow]
  public let cursor: String?

  public init(legacyRevision: Int64, rows: [ReadStateLegacyRow], cursor: String?) {
    self.legacyRevision = legacyRevision
    self.rows = rows
    self.cursor = cursor
  }
}
