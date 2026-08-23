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
    now: Date
  ) async throws -> WireCorpusPage
  func edition(language: String, region: WireViewerRegion?, now: Date) async throws -> WireEdition
  func item(id: String, now: Date) async throws -> WireCorpusItem?
  func catalog(now: Date) async throws -> WireCorpusCatalog
}
