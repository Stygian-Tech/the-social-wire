enum CircleGraphSnapshotError: Error, Equatable, Sendable {
  case invalidViewerDID
  case duplicateFollowRead(actorDID: String)
  case missingFollowRead(actorDID: String)
  case incompleteFollowRead(actorDID: String)
}
