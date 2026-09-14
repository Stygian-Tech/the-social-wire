import Foundation

/// A current public record observed at one stable repository revision.
/// The revision is an observation watermark, not the record's original commit.
struct WireVerifiedPublicRecord: Sendable {
  let uri: String
  let repoDID: String
  let collection: String
  let recordKey: String
  let cid: String
  let repositoryRevision: String
  let pdsBase: String
  let recordJSON: Data
  let observedAt: Date
}
