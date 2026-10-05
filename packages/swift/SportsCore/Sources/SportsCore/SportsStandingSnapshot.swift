import Foundation

public struct SportsStandingSnapshot: Codable, Equatable, Sendable {
  public let competitionID: String
  public let season: String
  public let sourceURL: String
  public let status: String
  public let updatedAt: Date?
  public let degraded: Bool
  public let rows: [SportsStandingRow]

  public init(competitionID: String, season: String, sourceURL: String = "https://www.thesportsdb.com/",
    status: String, updatedAt: Date? = nil, degraded: Bool = false, rows: [SportsStandingRow] = []) {
    self.competitionID = competitionID; self.season = season; self.sourceURL = sourceURL
    self.status = status; self.updatedAt = updatedAt; self.degraded = degraded; self.rows = rows
  }

  public func served(at now: Date, remoteFailed: Bool = false) -> Self {
    .init(competitionID: competitionID, season: season, sourceURL: sourceURL, status: status,
      updatedAt: updatedAt, degraded: remoteFailed || (updatedAt.map { now.timeIntervalSince($0) > 3600 } ?? true), rows: rows)
  }
}
