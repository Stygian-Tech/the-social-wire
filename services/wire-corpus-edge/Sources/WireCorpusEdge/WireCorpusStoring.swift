import Foundation
import WireCore

protocol WireCorpusStoring: Sendable {
  func ping() async throws
  func requireFreshBaseline(now: Date) async throws
  func feed(
    language: String,
    generationID: UUID?,
    startOrdinal: Int,
    limit: Int,
    fallbackLimit: Int?,
    now: Date
  ) async throws -> WireCorpusPage
  func edition(language: String, region: WireViewerRegion?, fallbackLimit: Int?, now: Date) async throws -> WireCorpusEdition
  func item(id: String, now: Date) async throws -> WireCorpusItem?
  func catalog(now: Date) async throws -> WireCorpusCatalog
  func circleCandidates(
    actorHashes: [String],
    language: String,
    since: Date,
    limit: Int,
    now: Date
  ) async throws -> WireCorpusCandidateResponse
}
