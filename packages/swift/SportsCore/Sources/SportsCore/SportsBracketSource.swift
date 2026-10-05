import Foundation

/// Reviewed official external destinations only; no bracket graph, logos or results are imported.
public struct SportsBracketSource: Codable, Equatable, Sendable {
  public let id: String
  public let competitionID: String
  public let season: String
  public let title: String
  public let url: String
  public let reviewedAt: Date
  public let mode: String
}
