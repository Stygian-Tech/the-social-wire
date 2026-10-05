import FinanceCore
import SportsCore
import Foundation
import WireCore

protocol WireCorpusStoring: Sendable {
  func sportsSchedules(now: Date) async throws -> [SportsScheduleStatus]
  func sportsStandings(now: Date, preferredIDs: [String]) async throws -> [SportsStandingSnapshot]
  func sportsEvents(now: Date, competitionIDs: [String], entityIDs: [String], global: Bool, teamIDs: [String]?, preferredIDs: [String], timeZone: TimeZone) async throws -> [SportsEvent]
  func sports(language: String, now: Date) async throws -> SportsSourceGeneration
  func finance(language: String, now: Date) async throws -> FinanceSourceGeneration
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

// Existing test stores and deployments can remain Wire-only until Finance is enabled.
extension WireCorpusStoring {
  func sportsEvents(now: Date, competitionIDs: [String], entityIDs: [String], global: Bool, teamIDs: [String]?, preferredIDs: [String], timeZone: TimeZone) async throws -> [SportsEvent] { [] }
  func sportsStandings(now: Date, preferredIDs: [String]) async throws -> [SportsStandingSnapshot] { [] }
  func sportsSchedules(now: Date) async throws -> [SportsScheduleStatus] { [] }
  func sports(language: String, now: Date) async throws -> SportsSourceGeneration { throw WireCorpusEdgeStoreError.unavailable }
  func finance(language: String, now: Date) async throws -> FinanceSourceGeneration {
    throw WireCorpusEdgeStoreError.unavailable
  }
}
