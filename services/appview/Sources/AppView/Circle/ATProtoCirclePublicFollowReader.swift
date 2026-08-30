import AsyncHTTPClient
import Foundation
import GatewayCore
import ThinAppViewCore

struct ATProtoCirclePublicFollowReader: CirclePublicFollowReading {
  private static let concurrency = 16
  private let httpClient: HTTPClient

  init(httpClient: HTTPClient) {
    self.httpClient = httpClient
  }

  func follows(of actorDIDs: Set<String>) async throws -> [CircleFollowList] {
    let actors = actorDIDs.sorted()
    guard !actors.isEmpty else { return [] }
    return try await withThrowingTaskGroup(of: CircleFollowList.self) { group in
      var next = 0
      var result: [CircleFollowList] = []
      while next < min(Self.concurrency, actors.count) {
        let actor = actors[next]
        group.addTask { try await list(actorDID: actor) }
        next += 1
      }
      while let currentList = try await group.next() {
        result.append(currentList)
        if next < actors.count {
          let actor = actors[next]
          group.addTask { try await list(actorDID: actor) }
          next += 1
        }
      }
      return result
    }
  }

  private func list(actorDID: String) async throws -> CircleFollowList {
    var followees: [String] = []
    var cursor: String?
    repeat {
      var components = URLComponents(
        string: "\(ATProtoPdsResolution.bskyAppViewPublic)/xrpc/app.bsky.graph.getFollows"
      )
      var query = [
        URLQueryItem(name: "actor", value: actorDID),
        URLQueryItem(name: "limit", value: "100"),
      ]
      if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
      components?.queryItems = query
      guard let url = components?.url?.absoluteString else {
        throw CircleGraphSnapshotError.incompleteFollowRead(actorDID: actorDID)
      }
      var request = HTTPClientRequest(url: url)
      request.headers.add(name: "Accept", value: "application/json")
      let response = try await httpClient.execute(request, timeout: .seconds(15))
      guard response.status.code == 200 else {
        throw CircleGraphSnapshotError.incompleteFollowRead(actorDID: actorDID)
      }
      let body = try await response.body.collect(upTo: 2 * 1_024 * 1_024)
      guard
        let document = try JSONSerialization.jsonObject(
          with: Data(buffer: body)
        ) as? [String: Any]
      else {
        throw CircleGraphSnapshotError.incompleteFollowRead(actorDID: actorDID)
      }
      for profile in document["follows"] as? [[String: Any]] ?? [] {
        if let did = profile["did"] as? String { followees.append(did) }
      }
      let nextCursor = document["cursor"] as? String
      guard nextCursor != cursor else {
        throw CircleGraphSnapshotError.incompleteFollowRead(actorDID: actorDID)
      }
      cursor = nextCursor
    } while cursor != nil
    return CircleFollowList(actorDID: actorDID, followeeDIDs: followees, isComplete: true)
  }
}
