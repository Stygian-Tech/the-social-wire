import Foundation

public struct SportsEntity: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let kind: String
  public let schoolID: String?
  public let gender: String?
  public let division: String?
  public let sportID: String?
  public let competitionIDs: [String]
  public let aliases: [String]
  public let providerIDs: [String: String]
  public let abbreviation: String?
  public let memberships: [SportsMembership]?
  public let groupPath: [String]?
  public let active: Bool
  public init(id: String, name: String, kind: String, sportID: String? = nil,
    competitionIDs: [String] = [], aliases: [String] = [], providerIDs: [String: String] = [:], active: Bool = true, memberships: [SportsMembership] = [], schoolID: String? = nil, gender: String? = nil, division: String? = nil, groupPath: [String]? = nil, abbreviation: String? = nil) {
    self.abbreviation = abbreviation
    self.groupPath = groupPath
    self.schoolID = schoolID; self.gender = gender; self.division = division; self.id = id; self.name = name; self.kind = kind; self.sportID = sportID
    self.memberships = memberships; self.competitionIDs = competitionIDs; self.aliases = aliases; self.providerIDs = providerIDs; self.active = active
  }
}
