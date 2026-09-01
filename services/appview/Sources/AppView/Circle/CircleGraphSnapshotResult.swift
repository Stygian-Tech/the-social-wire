struct CircleGraphSnapshotResult: Equatable, Sendable {
  let snapshot: CircleGraphSnapshot
  let freshness: CircleGraphSnapshotFreshness

  var isDegraded: Bool {
    freshness.isStale || snapshot.oneHopExpansionComplete == false
  }
}
