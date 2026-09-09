import Foundation
import ReadStateCore
import Testing
@testable import ThinAppViewCore

@Suite("Bounded verified PDS record cache")
struct PDSReadStateVerifiedRecordCacheTests {
  private let data = Data(PDSReadStateProjectorTests.Records.chunk.utf8)
  private func reference(_ viewer: String = "viewer") -> ReadStateReference {
    ReadStateReference(uri: "at://did:plc:\(viewer)/app.thesocialwire.readStateChunk/a",
      cid: PDSReadStateProjectorTests.Records.chunkCID)
  }

  @Test func viewerIdentityAndExpiryArePartOfCacheBoundary() async throws {
    let cache = PDSReadStateVerifiedRecordCache(ttl: 10)
    let now = Date(timeIntervalSince1970: 1_000)
    try await cache.insert(data, for: reference(), now: now)
    #expect(await cache.value(for: reference(), now: now) == data)
    #expect(await cache.value(for: reference("other"), now: now) == nil)
    #expect(await cache.value(for: reference(), now: now.addingTimeInterval(10)) == nil)
  }

  @Test func rejectsCorruptDataAndEvictsWithinOneSharedBudget() async throws {
    let cache = PDSReadStateVerifiedRecordCache(maximumBytes: data.count, maximumEntries: 2)
    let now = Date(timeIntervalSince1970: 1_000)
    try await cache.insert(data, for: reference(), now: now)
    await #expect(throws: (any Error).self) {
      try await cache.insert(Data("{}".utf8), for: reference(), now: now)
    }
    #expect(await cache.value(for: reference(), now: now) == data)
    try await cache.insert(data, for: reference("other"), now: now.addingTimeInterval(1))
    #expect(await cache.value(for: reference(), now: now.addingTimeInterval(1)) == nil)
    #expect(await cache.value(for: reference("other"), now: now.addingTimeInterval(1)) == data)
  }
}
