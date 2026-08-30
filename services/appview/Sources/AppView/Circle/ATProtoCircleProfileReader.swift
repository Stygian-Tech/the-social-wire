import AsyncHTTPClient
import Foundation
import GatewayCore
import ThinAppViewCore

struct ATProtoCircleProfileReader: CircleProfileReading {
  private let httpClient: HTTPClient

  init(httpClient: HTTPClient) {
    self.httpClient = httpClient
  }

  func profiles(actorDIDs: Set<String>) async throws -> [String: CirclePublicIdentity] {
    var result: [String: CirclePublicIdentity] = [:]
    for actors in actorDIDs.sorted().circleProfileChunks(maximum: 25) {
      var components = URLComponents(
        string: "\(ATProtoPdsResolution.bskyAppViewPublic)/xrpc/app.bsky.actor.getProfiles"
      )
      components?.queryItems = actors.map { URLQueryItem(name: "actors", value: $0) }
      guard let url = components?.url?.absoluteString else { throw WireServingError.unavailable }
      var request = HTTPClientRequest(url: url)
      request.headers.add(name: "Accept", value: "application/json")
      let response = try await httpClient.execute(request, timeout: .seconds(10))
      guard response.status.code == 200 else { throw WireServingError.unavailable }
      let body = try await response.body.collect(upTo: 2 * 1_024 * 1_024)
      guard
        let document = try JSONSerialization.jsonObject(
          with: Data(buffer: body)
        ) as? [String: Any]
      else { throw WireServingError.unavailable }
      for profile in document["profiles"] as? [[String: Any]] ?? [] {
        guard let did = profile["did"] as? String,
          let handle = profile["handle"] as? String
        else { continue }
        result[did] = CirclePublicIdentity(
          did: did,
          handle: handle,
          displayName: profile["displayName"] as? String,
          avatarURL: profile["avatar"] as? String
        )
      }
    }
    return result
  }
}

extension Array {
  fileprivate func circleProfileChunks(maximum: Int) -> [[Element]] {
    stride(from: 0, to: count, by: maximum).map { start in
      Array(self[start..<Swift.min(start + maximum, count)])
    }
  }
}
