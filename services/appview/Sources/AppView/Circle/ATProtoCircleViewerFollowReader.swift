import GatewayCore

struct ATProtoCircleViewerFollowReader: CircleViewerFollowReading {
  private let repo: ATProtoAuthenticatedRepoClient
  private let auth: AuthContext

  init(repo: ATProtoAuthenticatedRepoClient, auth: AuthContext, listRecordsProof: String) {
    self.repo = repo
    self.auth = AuthContext(
      did: auth.did,
      authorizationForwardingValue: auth.authorizationForwardingValue,
      dpopProof: auth.dpopProof,
      upstreamDpopProof: listRecordsProof
    )
  }

  func follows(viewerDID: String) async throws -> CircleFollowList {
    var followees: [String] = []
    var cursor: String?
    repeat {
      let page = try await repo.listRecords(
        auth: auth,
        repo: viewerDID,
        collection: "app.bsky.graph.follow",
        limit: 100,
        cursor: cursor,
        reverse: false
      )
      for record in page.records {
        if let subject = record.value.values["subject"] as? String {
          followees.append(subject)
        }
      }
      guard page.cursor != cursor else {
        throw CircleGraphSnapshotError.incompleteFollowRead(actorDID: viewerDID)
      }
      cursor = page.cursor
    } while cursor != nil
    return CircleFollowList(actorDID: viewerDID, followeeDIDs: followees, isComplete: true)
  }
}
