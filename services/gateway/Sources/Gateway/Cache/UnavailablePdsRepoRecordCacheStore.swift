import Foundation
import GatewayCore

actor UnavailablePdsRepoRecordCacheStore: PdsRepoRecordCacheStore {
  func cachedPdsRepoRecord(ownerDid: String, scopeKey: String) async throws -> PdsCachedRepoRecordPayload? {
    _ = ownerDid
    _ = scopeKey
    return nil
  }

  func storePdsRepoRecordPayload(
    ownerDid: String,
    scopeKey: String,
    cid: String?,
    jsonBody: String,
    cachedAt: Date,
    expiresAt: Date
  ) async throws {
    _ = ownerDid
    _ = scopeKey
    _ = cid
    _ = jsonBody
    _ = cachedAt
    _ = expiresAt
  }
}
