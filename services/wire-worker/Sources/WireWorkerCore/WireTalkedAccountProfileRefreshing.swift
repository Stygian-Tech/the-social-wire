import Foundation

protocol WireTalkedAccountProfileFetching: Sendable {
  func fetch(did: String) async throws -> WireTalkedAccountProfile
}

protocol WireTalkedAccountProfileStoring: Sendable {
  func claimDue(limit: Int, asOf: Date) async throws -> [String]
  func store(_ profile: WireTalkedAccountProfile, asOf: Date) async throws
  func markFailure(did: String, asOf: Date) async throws
}
