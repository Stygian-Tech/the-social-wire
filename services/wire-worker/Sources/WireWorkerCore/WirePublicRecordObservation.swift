import Foundation

/// Metadata-only evidence for a missing, changed or inactive public record.
/// Inactivity can be observed without a readable repository revision.
struct WirePublicRecordObservation: Sendable {
  let uri: String
  let expectedCID: String?
  let repositoryRevision: String?
  let pdsBase: String
  let observedAt: Date
}
