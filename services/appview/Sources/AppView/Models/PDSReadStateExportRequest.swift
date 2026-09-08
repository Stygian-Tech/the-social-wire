import Foundation

struct PDSReadStateExportRequest: Decodable, Sendable {
  let cursor: String?
  let expectedLegacyRevision: Int64?
  let limit: Int?
}
