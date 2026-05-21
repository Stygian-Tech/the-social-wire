import Foundation

/// Cached opaque XRPC **`com.atproto.repo.getRecord`** response JSON (stringified).
public struct PdsCachedRepoRecordPayload: Codable, Sendable {
  public let cid: String?
  public let jsonBody: String
  public let cachedAt: Date

  public init(cid: String?, jsonBody: String, cachedAt: Date) {
    self.cid = cid
    self.jsonBody = jsonBody
    self.cachedAt = cachedAt
  }
}
