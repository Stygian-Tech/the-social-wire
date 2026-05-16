import Foundation

/// Cached opaque XRPC **`com.atproto.repo.getRecord`** response JSON (stringified).
struct PdsCachedRepoRecordPayload: Codable, Sendable {
  let cid: String?
  let jsonBody: String
  let cachedAt: Date
}
