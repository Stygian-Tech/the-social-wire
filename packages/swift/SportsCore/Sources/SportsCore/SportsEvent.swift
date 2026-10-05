import Foundation

public struct SportsEvent: Codable, Equatable, Sendable {
  public let id: String
  public let competitionID: String
  public let entityIDs: [String]
  public let title: String
  public let startsAt: Date
  public let startTimeKnown: Bool?
  public let status: String
  public let homeName: String?
  public let awayName: String?
  public let homeAbbreviation: String?
  public let awayAbbreviation: String?
  public let homeScore: String?
  public let awayScore: String?
  public let updatedAt: Date
  public init(id: String, competitionID: String, entityIDs: [String] = [], title: String, startsAt: Date,
    status: String, homeName: String? = nil, awayName: String? = nil, homeScore: String? = nil, awayScore: String? = nil, homeAbbreviation: String? = nil, awayAbbreviation: String? = nil, startTimeKnown: Bool? = nil, updatedAt: Date) {
    self.id = id; self.competitionID = competitionID; self.entityIDs = entityIDs; self.title = title
    self.startTimeKnown = startTimeKnown; self.startsAt = startsAt; self.status = status; self.homeName = homeName; self.awayName = awayName
    self.homeAbbreviation = homeAbbreviation; self.awayAbbreviation = awayAbbreviation
    self.homeScore = homeScore; self.awayScore = awayScore; self.updatedAt = updatedAt
  }
}
