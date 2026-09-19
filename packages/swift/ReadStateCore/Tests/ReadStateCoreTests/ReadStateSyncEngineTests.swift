import Foundation
import Testing
@testable import ReadStateCore

@Suite struct ReadStateSyncEngineTests {
  @Test func bulkPublicationAndRestartAfterAmbiguousCommit() async throws {
    let fixture = SyncFixture()
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/outbox.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let engine = try ReadStateSyncEngine(viewerDid: fixture.viewer, file: file, transport: fixture.transport())
    let actions = (0..<150).map { operation("action-\($0)", uri: "story-\($0)") }
    try await engine.enqueue(actions)
    await fixture.failConfirmationOnce()
    await #expect(throws: URLError.self) { try await engine.flush() }
    #expect(await engine.pendingCount == 1)
    #expect(await fixture.chunkCount == 2)
    #expect(await fixture.manifestWrites == 1)
    let resumed = try ReadStateSyncEngine(viewerDid: fixture.viewer, file: file, transport: fixture.transport())
    try await resumed.flush(now: Date().addingTimeInterval(1000))
    #expect(await resumed.pendingCount == 0)
    #expect(await fixture.manifestWrites == 1)
    #expect(await fixture.chunkCount == 2)
  }

  @Test func throttleSurvivesRestartAndAdjacentIntentCoalesces() async throws {
    let fixture = SyncFixture()
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/outbox.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let engine = try ReadStateSyncEngine(viewerDid: fixture.viewer, file: file, transport: fixture.transport())
    try await engine.enqueue([operation("read", uri: "one")])
    try await engine.enqueue([operation("unread", uri: "one", state: .unread)])
    #expect(await engine.pendingCount == 1)
    let until = Date().addingTimeInterval(60)
    await fixture.throttle(until)
    await #expect(throws: ReadStateSyncFailure.self) { try await engine.flush() }
    let resumed = try ReadStateSyncEngine(viewerDid: fixture.viewer, file: file, transport: fixture.transport())
    let calls = await fixture.reads
    try await resumed.flush()
    #expect(await fixture.reads == calls)
    try await resumed.flush(now: until.addingTimeInterval(1))
    #expect(await resumed.pendingCount == 0)
    #expect(await fixture.lastState == .unread)
    #expect(throws: ReadStateSyncFailure.self) {
      try ReadStateSyncEngine(viewerDid: "did:plc:other", file: file, transport: fixture.transport())
    }
  }

  @Test func chunkRetryIsIdempotentAndUncommittedDataIsInvisible() async throws {
    let fixture = SyncFixture()
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/outbox.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let engine = try ReadStateSyncEngine(viewerDid: fixture.viewer, file: file, transport: fixture.transport())
    try await engine.enqueue([operation("one", uri: "story")])
    await fixture.failChunkOnce()
    await #expect(throws: URLError.self) { try await engine.flush() }
    #expect(await fixture.manifestWrites == 0)
    #expect(await fixture.chunkCount == 1)
    let resumed = try ReadStateSyncEngine(viewerDid: fixture.viewer, file: file, transport: fixture.transport())
    try await resumed.flush(now: Date().addingTimeInterval(1000))
    #expect(await fixture.chunkCount == 1)
    #expect(await fixture.manifestWrites == 1)
  }

  @Test func denseRepackingPreservesEveryActionAndRetryIdentity() async throws {
    let fixture = SyncFixture()
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/outbox.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let engine = try ReadStateSyncEngine(viewerDid: fixture.viewer, file: file, transport: fixture.transport())
    for index in 0..<70 {
      try await engine.enqueue([operation("action-\(index)", uri: "story-\(index)")])
      try await engine.flush()
    }
    let record = try #require(await fixture.record)
    let projection = try await fixture.projection(record.manifest)
    #expect(projection.sourceChunkCount < 10)
    #expect(projection.actionIds.count == 70)
    #expect(projection.lastSequence == 70)
    // A retired chunk stays on the repository, but an old ambiguous action is
    // still present in the dense manifest and does not publish twice.
    #expect(await fixture.chunkCount >= 70)
    try await engine.enqueue([operation("action-0", uri: "story-0")])
    try await engine.flush()
    #expect(await fixture.manifestWrites == 70)
    #expect(await fixture.record?.cid == record.cid)
  }

  @Test func ambiguousConfirmationUsesNewerCompleteManifest() async throws {
    let fixture = SyncFixture()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try ReadStateSyncEngine(viewerDid: fixture.viewer,
      file: directory.appending(path: "first.json"), transport: fixture.transport())
    try await first.enqueue([operation("one", uri: "story-one")])
    await fixture.failConfirmationOnce()
    await #expect(throws: URLError.self) { try await first.flush() }
    let other = try ReadStateSyncEngine(viewerDid: fixture.viewer,
      file: directory.appending(path: "other.json"), transport: fixture.transport())
    try await other.enqueue([operation("two", uri: "story-two")])
    try await other.flush()
    try await first.flush(now: Date().addingTimeInterval(1000))
    #expect(await first.pendingCount == 0)
    #expect(await fixture.manifestWrites == 2)
    #expect(await fixture.confirmedCids.last == "manifest-2")
  }

  @Test func migrationCanReplaceOnlyTheExplicitUnverifiedCandidate() async throws {
    let fixture = SyncFixture(activated: false)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = try ReadStateSyncEngine(viewerDid: fixture.viewer,
      file: directory.appending(path: "migration.json"), transport: fixture.transport())
    try await engine.enqueue([operation("old-baseline", uri: "story-one")], expectedLegacyRevision: 1)
    await fixture.failConfirmationOnce()
    await #expect(throws: URLError.self) { try await engine.flush() }
    let old = try #require(await fixture.record)
    // Caller re-exported under the server's still-AppView authority and revision.
    try await engine.replaceUnverifiedMigration([operation("new-baseline", uri: "story-two")],
      legacyRevision: 2, replacingManifestCid: old.cid)
    try await engine.flush(now: Date().addingTimeInterval(1000))
    let current = try #require(await fixture.record)
    let projection = try await fixture.projection(current.manifest)
    #expect(projection.actionIds == ["new-baseline"])
    #expect(projection.lastSequence == 1)
    #expect(projection.sourceChunkCount == 1)
    #expect(await fixture.confirmedRevisions.last == 2)
    #expect(await fixture.chunkCount == 2)
    // A stale exported candidate cannot overwrite a concurrent PDS manifest.
    try await engine.replaceUnverifiedMigration([operation("stale", uri: "story-three")],
      legacyRevision: 3, replacingManifestCid: old.cid)
    await #expect(throws: ReadStateSyncFailure.self) {
      try await engine.flush(now: Date().addingTimeInterval(2000))
    }
    #expect(await fixture.record?.cid == current.cid)
  }

  @Test func manifestExtensionsSurvivePublicationAndRestart() async throws {
    let fixture = SyncFixture()
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/outbox.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let extensions: [String: ReadStateJSONValue] = ["future": .object(["enabled": .boolean(true),
      "values": .array([.integer(12), .null, .string("extension")])])]
    await fixture.seedManifest(ReadStateManifest(generation: "external", lastSequence: 0,
      head: nil, extensions: extensions))
    let engine = try ReadStateSyncEngine(viewerDid: fixture.viewer, file: file, transport: fixture.transport())
    try await engine.enqueue([operation("one", uri: "story")])
    await fixture.failChunkOnce()
    await #expect(throws: URLError.self) { try await engine.flush() }
    let resumed = try ReadStateSyncEngine(viewerDid: fixture.viewer, file: file, transport: fixture.transport())
    try await resumed.flush(now: Date().addingTimeInterval(1000))
    #expect(await fixture.record?.manifest.extensions == extensions)
  }


  @Test func missingActiveManifestNeverCreatesAnEmptyReplacement() async throws {
    let fixture = SyncFixture()
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/outbox.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let engine = try ReadStateSyncEngine(viewerDid: fixture.viewer, file: file, transport: fixture.transport())
    try await engine.enqueue([operation("existing", uri: "story-one")])
    try await engine.flush()
    try await engine.enqueue([operation("pending", uri: "story-two", state: .unread)])
    await fixture.removeManifest()
    await #expect(throws: ReadStateError.self) { try await engine.flush() }
    #expect(await fixture.manifestWrites == 1)
    #expect(await fixture.chunkCount == 1)
    #expect(await fixture.record == nil)
    let restarted = try ReadStateSyncEngine(viewerDid: fixture.viewer, file: file, transport: fixture.transport())
    #expect(await restarted.pendingCount == 1)
    await #expect(throws: ReadStateError.self) { try await restarted.flush(now: Date().addingTimeInterval(1000)) }
    #expect(await fixture.manifestWrites == 1)
    #expect(await fixture.chunkCount == 1)
  }

  private func operation(_ id: String, uri: String, state: ReadStateOperation.State = .read) -> ReadStateOperation {
    .init(actionId: id, sequence: 1, state: state, actedAt: "2026-09-08T00:00:00Z", subjectUris: [uri])
  }
}

private actor SyncFixture {
  nonisolated let viewer = "did:plc:fixture"
  var record: ReadStateManifestRecord?
  init(activated: Bool = true) {
    if activated { record = .init(manifest: .init(generation: "activated", lastSequence: 0, head: nil), cid: "activated") }
  }
  func removeManifest() { record = nil }
  var chunks: [String: ReadStateChunk] = [:]
  var reads = 0
  var manifestWrites = 0
  var confirmedCids: [String] = []
  var confirmedRevisions: [Int64?] = []
  var confirmationFailure = false
  var chunkFailure = false
  var throttleUntil: Date?
  var chunkCount: Int { chunks.count }
  var lastState: ReadStateOperation.State? { chunks.values.first?.operations.last?.state }

  func seedManifest(_ manifest: ReadStateManifest) { record = .init(manifest: manifest, cid: "external") }
  func failConfirmationOnce() { confirmationFailure = true }
  func failChunkOnce() { chunkFailure = true }
  func throttle(_ until: Date) { throttleUntil = until }
  nonisolated func transport() -> ReadStateSyncTransport {
    .init(readManifest: { try await self.read() }, loadProjection: { try await self.projection($0) },
      putChunk: { try await self.putChunk($0, $1) }, putManifest: { try await self.putManifest($0, $1) },
      confirm: { cid, revision in try await self.confirm(cid, revision: revision) })
  }
  func read() throws -> ReadStateManifestRecord? {
    reads += 1
    if let until = throttleUntil { throttleUntil = nil; throw ReadStateSyncFailure.rateLimited(until: until) }
    return record
  }
  func projection(_ manifest: ReadStateManifest) async throws -> ReadStateProjection {
    try await ReadStateGenerationLoader.load(manifest: manifest, viewerDid: viewer) { reference in
      try await self.chunk(reference)
    }
  }
  func chunk(_ reference: ReadStateReference) throws -> ReadStateChunk {
    guard let chunk = chunks[reference.uri] else { throw ReadStateError.invalidReference }
    return chunk
  }
  func putChunk(_ key: String, _ chunk: ReadStateChunk) throws -> ReadStateReference {
    let uri = "at://\(viewer)/\(ReadStateChunk.collection)/\(key)"
    if let old = chunks[uri] { #expect(old == chunk) }
    chunks[uri] = chunk
    if chunkFailure { chunkFailure = false; throw URLError(.networkConnectionLost) }
    return .init(uri: uri, cid: "cid-\(key)")
  }
  func putManifest(_ manifest: ReadStateManifest, _ expected: String?) throws -> String {
    guard record?.cid == expected else { throw ReadStateSyncFailure.conflict }
    manifestWrites += 1
    let cid = "manifest-\(manifestWrites)"
    record = .init(manifest: manifest, cid: cid)
    return cid
  }
  func confirm(_ cid: String, revision: Int64?) throws {
    guard record?.cid == cid else { throw ReadStateSyncFailure.conflict }
    if confirmationFailure { confirmationFailure = false; throw URLError(.networkConnectionLost) }
    confirmedCids.append(cid)
    confirmedRevisions.append(revision)
  }
}
