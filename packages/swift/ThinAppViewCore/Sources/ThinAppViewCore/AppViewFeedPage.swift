import Foundation

public struct AppViewFeedPage: Sendable {
  public let response: AppViewEntryListResponse
  public let membershipUpdatedAt: Date
  public let databaseDurationMilliseconds: Double

  public init(
    response: AppViewEntryListResponse,
    membershipUpdatedAt: Date,
    databaseDurationMilliseconds: Double
  ) {
    self.response = response
    self.membershipUpdatedAt = membershipUpdatedAt
    self.databaseDurationMilliseconds = databaseDurationMilliseconds
  }
}
