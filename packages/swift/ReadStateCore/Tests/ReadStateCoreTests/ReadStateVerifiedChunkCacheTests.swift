import Foundation
import Testing
@testable import ReadStateCore

@Test func verifiedChunkCacheIsBoundedExpiringAndViewerIsolated() async throws {
  let cache = ReadStateVerifiedChunkCache(maximumEntries: 1, ttl: 10)
  let a = ReadStateReference(uri: "at://did:plc:a/app.thesocialwire.readStateChunk/a", cid: "cid")
  let b = ReadStateReference(uri: "at://did:plc:b/app.thesocialwire.readStateChunk/a", cid: "cid")
  let chunk = ReadStateChunk(operations: [], previous: nil)
  let now = Date(timeIntervalSince1970: 100)
  try await cache.insertVerified(chunk, for: a, now: now)
  #expect(await cache.value(for: a, now: now) != nil)
  #expect(await cache.value(for: b, now: now) == nil)
  try await cache.insertVerified(chunk, for: b, now: now.addingTimeInterval(1))
  #expect(await cache.value(for: a, now: now.addingTimeInterval(2)) == nil)
  #expect(await cache.value(for: b, now: now.addingTimeInterval(11)) == nil)
}
