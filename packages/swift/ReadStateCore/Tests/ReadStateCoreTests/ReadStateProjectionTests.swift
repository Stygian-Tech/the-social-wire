import Foundation
import Testing
@testable import ReadStateCore

private let viewer = "did:plc:viewer"
private let scope = ReadStateScope(publicationId: "at://did:plc:author/site.standard.publication/self",
  authorDid: "did:plc:author", publicationSiteKeys: ["https://example.com"])
private let moment = "2026-09-08T12:00:00.000Z"

private func subject(_ id: String, at: String = moment, author: String = "did:plc:author",
                     site: String = "https://example.com") throws -> ReadStateSubject {
  ReadStateSubject(uri: id, authorDid: author, publicationSite: site,
    createdAt: try ReadStateValidation.date(at))
}

@Test func boundaryTieAndLateBackfillMatchLegacySemantics() throws {
  let op = ReadStateOperation(actionId: "bulk", sequence: 1, state: .read, actedAt: moment,
    boundaries: [ReadStateBoundary(scope: scope, createdAt: moment, entryId: "b")])
  let projection = try ReadStateProjection(operations: [op], lastSequence: 1)
  #expect(projection.resolve(try subject("a")).isRead)
  #expect(projection.resolve(try subject("b")).isRead)
  #expect(!projection.resolve(try subject("c")).isRead)
  #expect(projection.resolve(try subject("z", at: "2020-01-01T00:00:00Z")).isRead)
  #expect(!projection.resolve(try subject("a", site: "https://other.com")).isRead)
  #expect(!projection.resolve(try subject("a", author: "did:plc:other")).isRead)
}

@Test func exactAgeSelectionDoesNotReadLateArrivals() throws {
  let op = ReadStateOperation(actionId: "age", sequence: 1, state: .read, actedAt: moment,
    subjectUris: ["known-old"])
  let projection = try ReadStateProjection(operations: [op], lastSequence: 1)
  #expect(projection.resolve(try subject("known-old")).isRead)
  #expect(!projection.resolve(try subject("late-old", at: "2020-01-01T00:00:00Z")).isRead)
}

@Test func committedSequenceOverridesClockSkewAndInputOrder() throws {
  let bulk = ReadStateOperation(actionId: "bulk", sequence: 1, state: .read, actedAt: moment,
    boundaries: [ReadStateBoundary(scope: scope, createdAt: moment, entryId: nil)])
  let unread = ReadStateOperation(actionId: "unread", sequence: 2, state: .unread,
    actedAt: "2020-01-01T00:00:00Z", subjectUris: ["a"])
  let readAgain = ReadStateOperation(actionId: "later-bulk", sequence: 3, state: .read,
    actedAt: "2021-01-01T00:00:00Z", boundaries: bulk.boundaries!)
  let projection = try ReadStateProjection(operations: [unread, bulk], lastSequence: 2)
  #expect(!projection.resolve(try subject("a")).isRead)
  #expect(projection.resolve(try subject("b")).isRead)
  let later = try ReadStateProjection(operations: [readAgain, unread, bulk], lastSequence: 3)
  #expect(later.resolve(try subject("a")).isRead)
  #expect(later.resolve(try subject("a")).readAt == "2021-01-01T00:00:00Z")
}

@Test func conflictingSequenceFailsInsteadOfInventingTieBreak() throws {
  let first = ReadStateOperation(actionId: "one", sequence: 1, state: .read, actedAt: moment, subjectUris: ["a"])
  let conflict = ReadStateOperation(actionId: "two", sequence: 1, state: .unread, actedAt: moment, subjectUris: ["a"])
  #expect(throws: ReadStateError.conflictingSequence) {
    try ReadStateProjection(operations: [first, conflict], lastSequence: 1)
  }
  #expect(throws: ReadStateError.incompleteGeneration) {
    try ReadStateProjection(operations: [first], lastSequence: 2)
  }
}

@Test func generationRejectsForeignChunkAndCycle() async throws {
  let foreign = ReadStateReference(uri: "at://did:plc:other/app.thesocialwire.readStateChunk/a", cid: "cid")
  #expect(throws: ReadStateError.invalidReference) {
    try ReadStateValidation.validate(foreign, viewerDid: viewer)
  }
  let reference = ReadStateReference(uri: "at://\(viewer)/app.thesocialwire.readStateChunk/a", cid: "cid")
  let manifest = ReadStateManifest(generation: "g", lastSequence: 1, head: reference)
  let op = ReadStateOperation(actionId: "one", sequence: 1, state: .read, actedAt: moment, subjectUris: ["a"])
  await #expect(throws: ReadStateError.invalidReference) {
    try await ReadStateGenerationLoader.load(manifest: manifest, viewerDid: viewer) { _ in
      ReadStateChunk(operations: [op], previous: reference)
    }
  }
}

@Test func onlyCompleteReferencedGenerationIsReturned() async throws {
  let reference = ReadStateReference(uri: "at://\(viewer)/app.thesocialwire.readStateChunk/a", cid: "cid")
  let manifest = ReadStateManifest(generation: "g", lastSequence: 1, head: reference)
  let op = ReadStateOperation(actionId: "one", sequence: 1, state: .read, actedAt: moment, subjectUris: ["a"])
  let projection = try await ReadStateGenerationLoader.load(manifest: manifest, viewerDid: viewer) { _ in
    ReadStateChunk(operations: [op], previous: nil)
  }
  #expect(projection.resolve(try subject("a")).isRead)
  await #expect(throws: ReadStateError.incompleteGeneration) {
    try await ReadStateGenerationLoader.load(manifest: manifest, viewerDid: viewer) { _ in
      throw ReadStateError.incompleteGeneration
    }
  }
  await #expect(throws: ReadStateError.sizeLimit) {
    try await ReadStateGenerationLoader.load(manifest: manifest, viewerDid: viewer, maximumBytes: 1) { _ in
      ReadStateChunk(operations: [op], previous: nil)
    }
  }
}

@Test func microsecondBoundaryDoesNotRoundIntoURITie() throws {
  let boundary = "2026-09-08T12:00:00.123456Z"
  let operation = ReadStateOperation(actionId: "microsecond", sequence: 1, state: .read, actedAt: moment,
    boundaries: [.init(scope: scope, createdAt: boundary, entryId: "m")])
  let projection = try ReadStateProjection(operations: [operation], lastSequence: 1)
  #expect(projection.resolve(try subject("z", at: "2026-09-08T12:00:00.123455Z")).isRead)
  #expect(projection.resolve(try subject("a", at: boundary)).isRead)
  #expect(!projection.resolve(try subject("z", at: boundary)).isRead)
  #expect(!projection.resolve(try subject("a", at: "2026-09-08T12:00:00.123457Z")).isRead)
  #expect(try ReadStateValidation.date(boundary) == ReadStateValidation.date("2026-09-08T14:00:00.123456+02:00"))
}
