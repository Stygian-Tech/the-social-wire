enum CircleFollowPagination {
  static func nextCursor(
    current: String?,
    returned: String?,
    actorDID: String
  ) throws -> String? {
    guard let returned else { return nil }
    guard returned != current else {
      throw CircleGraphSnapshotError.incompleteFollowRead(actorDID: actorDID)
    }
    return returned
  }
}
