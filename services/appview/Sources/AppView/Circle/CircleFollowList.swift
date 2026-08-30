struct CircleFollowList: Equatable, Sendable {
  let actorDID: String
  let followeeDIDs: [String]
  let isComplete: Bool
}
