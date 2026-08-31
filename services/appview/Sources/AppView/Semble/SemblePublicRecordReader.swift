import Foundation
import GatewayCore

struct SemblePublicRecord: Sendable {
  let collection: String
  let uri: String
  let cid: String?
  let value: Data
}

struct SemblePublicRecordRead: Sendable {
  let records: [SemblePublicRecord]
  let complete: Bool
}

protocol SemblePublicRecordReading: Sendable {
  func read(repoDid: String, collections: [String]) async throws -> SemblePublicRecordRead
}

struct ATProtoSemblePublicRecordReader: SemblePublicRecordReading {
  private static let maximumPagesPerCollection = 20
  let repo: ATProtoAuthenticatedRepoClient

  func read(repoDid: String, collections: [String]) async throws -> SemblePublicRecordRead {
    var records: [SemblePublicRecord] = []
    var complete = true
    for collection in collections {
      var cursor: String?
      var pages = 0
      repeat {
        let page = try await repo.listRecords(
          auth: nil,
          repo: repoDid,
          collection: collection,
          limit: 100,
          cursor: cursor,
          reverse: true
        )
        for record in page.records {
          guard JSONSerialization.isValidJSONObject(record.value.values) else { continue }
          records.append(
            SemblePublicRecord(
              collection: collection,
              uri: record.uri,
              cid: record.cid,
              value: try JSONSerialization.data(withJSONObject: record.value.values)
            )
          )
        }
        cursor = page.cursor
        pages += 1
      } while cursor != nil && pages < Self.maximumPagesPerCollection
      if cursor != nil { complete = false }
    }
    return SemblePublicRecordRead(records: records, complete: complete)
  }
}
