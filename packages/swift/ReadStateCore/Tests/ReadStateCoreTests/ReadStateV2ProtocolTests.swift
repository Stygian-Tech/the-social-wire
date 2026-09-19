import Foundation
import Testing
@testable import ReadStateCore

@Suite struct ReadStateV2ProtocolTests {
  let viewer = "did:plc:viewer"
  func operation(_ id: String, state: ReadStateOperation.State = .read, uri: String = "story") -> ReadStateOperation {
    .init(actionId: id, sequence: 1, state: state, actedAt: "2026-09-08T12:00:00Z",
      subjectUris: ["at://did:plc:author/site.standard.document/\(uri)"])
  }
  func file() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/outbox.json") }

  @Test func confirmedUpgradeRetainsLegacyReceiptsAndSemanticCompaction() async throws {
    let fixture = V2SyncFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let engine = try ReadStateSyncEngine(viewerDid: viewer, file: url, transport: fixture.transport())
    try await engine.enqueue([operation("read")]); try await engine.flush()
    try await engine.enqueue([operation("unread", state: .unread)]); try await engine.flush()
    let before = try await fixture.currentProjection()
    try await engine.upgradeToV2()
    let after = try await fixture.currentProjection()
    #expect(after.protocolVersion == 2)
    #expect(after.lastSequence == before.lastSequence)
    #expect(after.operations.count == 1)
    #expect(after.legacyReceipts.count == 2)
    #expect(after.operations.first?.actionId == "unread")
    #expect(after.sourceReferences.count == 3)
    #expect(after.sourceBytesByKind.keys.count == 3)
    let manifest = try #require(await fixture.record?.manifest)
    #expect(manifest.head == nil)
    #expect(manifest.effectiveRevision > before.lastSequence)
  }

  @Test func upgradeCannotPublishBeforeAuthorityConfirmation() async throws {
    let fixture = V2SyncFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let engine = try ReadStateSyncEngine(viewerDid: viewer, file: url, transport: fixture.transport())
    await fixture.failConfirmOnce()
    await #expect(throws: URLError.self) { try await engine.upgradeToV2() }
    #expect(await fixture.manifestWrites == 0)
    #expect(await fixture.chunkCount == 0)
  }

  @Test func countersCoalesceWithoutGapsAndSurviveRestart() async throws {
    let fixture = V2SyncFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let engine = try ReadStateSyncEngine(viewerDid: viewer, file: url, transport: fixture.transport())
    try await engine.upgradeToV2()
    try await engine.enqueue([operation("one")])
    try await engine.enqueue([operation("two", state: .unread)])
    try await engine.enqueue([operation("three", uri: "another")])
    #expect(await engine.pendingCount == 2)
    let resumed = try ReadStateSyncEngine(viewerDid: viewer, file: url, transport: fixture.transport())
    try await resumed.flush()
    #expect(await resumed.pendingCount == 0)
    let projection = try await fixture.currentProjection()
    #expect(projection.lastSequence == 2)
    #expect(projection.deviceReceipts.first?.committedCounter == 2)
    #expect(Set(projection.operations.map(\.actionId)) == ["two", "three"])
  }

  @Test func unknownSuccessAcknowledgesPrefixAfterAnotherDeviceCompactsAwayAction() async throws {
    let fixture = V2SyncFixture(); let firstURL = file(); let secondURL = file()
    defer { try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent()); try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent()) }
    let first = try ReadStateSyncEngine(viewerDid: viewer, file: firstURL, transport: fixture.transport())
    try await first.upgradeToV2()
    try await first.enqueue([operation("old")])
    await fixture.failConfirmAfterNextWrite()
    await #expect(throws: URLError.self) { try await first.flush() }
    #expect(await first.pendingCount == 1)
    let second = try ReadStateSyncEngine(viewerDid: viewer, file: secondURL, transport: fixture.transport())
    try await second.upgradeToV2()
    try await second.enqueue([operation("new", state: .unread)])
    try await second.flush(); try await second.compactV2()
    let compact = try await fixture.currentProjection()
    #expect(compact.operations.count == 1)
    #expect(compact.operations[0].actionId == "new")
    let writes = await fixture.manifestWrites
    let resumed = try ReadStateSyncEngine(viewerDid: viewer, file: firstURL, transport: fixture.transport())
    try await resumed.flush(now: Date().addingTimeInterval(1000))
    #expect(await resumed.pendingCount == 0)
    #expect(await fixture.manifestWrites == writes)
    #expect(try await fixture.currentProjection().lastSequence == 2)
  }

  @Test func successfulV2RecoveryClearsPersistedBackoffBeforeTheNextFailure() async throws {
    let fixture = V2SyncFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let engine = try ReadStateSyncEngine(viewerDid: viewer, file: url, transport: fixture.transport())
    try await engine.upgradeToV2()
    try await engine.enqueue([operation("first")])
    await fixture.failConfirmAfterNextWrite()
    await #expect(throws: URLError.self) { try await engine.flush() }
    #expect(await engine.outbox.failures == 1)
    #expect(await engine.retryAfter != nil)
    let recoveredAt = Date().addingTimeInterval(1000)
    try await engine.flush(now: recoveredAt)
    #expect(await engine.pendingCount == 0)
    #expect(await engine.retryAfter == nil)
    let restarted = try ReadStateSyncEngine(viewerDid: viewer, file: url, transport: fixture.transport())
    #expect(await restarted.outbox.failures == 0)
    try await restarted.enqueue([operation("second", state: .unread)])
    await fixture.failConfirmAfterNextWrite()
    await #expect(throws: URLError.self) { try await restarted.flush(now: recoveredAt) }
    #expect(await restarted.outbox.failures == 1)
    #expect(await restarted.pendingCount == 1)
  }

  @Test func legacyRetryAdvancesOnlyReceipt() async throws {
    let fixture = V2SyncFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let engine = try ReadStateSyncEngine(viewerDid: viewer, file: url, transport: fixture.transport())
    try await engine.enqueue([operation("old")]); try await engine.flush()
    try await engine.upgradeToV2()
    try await engine.enqueue([operation("old")]); try await engine.flush()
    let projection = try await fixture.currentProjection()
    #expect(projection.lastSequence == 1)
    #expect(projection.operations.count == 1)
    #expect(projection.deviceReceipts.first?.committedCounter == 1)
    #expect(await engine.pendingCount == 0)
  }

  @Test func competingDevicesRetryCASWithoutLosingEitherIntent() async throws {
    let fixture = V2SyncFixture(); let firstURL = file(); let secondURL = file()
    defer { try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent()); try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent()) }
    let first = try ReadStateSyncEngine(viewerDid: viewer, file: firstURL, transport: fixture.transport())
    let second = try ReadStateSyncEngine(viewerDid: viewer, file: secondURL, transport: fixture.transport())
    try await first.upgradeToV2(); try await second.upgradeToV2()
    try await first.enqueue([operation("first", uri: "one")]); try await second.enqueue([operation("second", uri: "two")])
    await fixture.raceNextReads()
    func flush(_ engine: ReadStateSyncEngine) async throws -> Bool {
      do { try await engine.flush(); return true } catch ReadStateSyncFailure.conflict { return false }
    }
    async let a = flush(first); async let b = flush(second)
    let outcomes = try await [a, b]
    #expect(outcomes.filter { !$0 }.count >= 1)
    try await first.flush(now: Date().addingTimeInterval(1000))
    try await second.flush(now: Date().addingTimeInterval(1000))
    let projection = try await fixture.currentProjection()
    #expect(projection.lastSequence == 2)
    #expect(Set(projection.operations.map(\.actionId)) == ["first", "second"])
    #expect(projection.deviceReceipts.filter { $0.committedCounter == 1 }.count == 2)
  }

  @Test func normalWritesAutomaticallyCompactAndDoNotDoubleCountRetiredRoots() async throws {
    let fixture = V2SyncFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let engine = try ReadStateSyncEngine(viewerDid: viewer, file: url, transport: fixture.transport())
    try await engine.upgradeToV2()
    for index in 0..<70 {
      try await engine.enqueue([operation("action-\(index)", state: index.isMultiple(of: 2) ? .read : .unread)])
      try await engine.flush()
    }
    let projection = try await fixture.currentProjection()
    #expect(projection.lastSequence == 70)
    #expect(projection.operations.count < 10)
    #expect(projection.deviceReceipts.first?.committedCounter == 70)
    let current = try #require(await fixture.record)
    let nearCap = try ReadStateProjection(operations: projection.operations, lastSequence: projection.lastSequence,
      sourceChunkCount: 4090, sourceBytes: 16 * 1024 * 1024 - 100,
      protocolVersion: 2, v2Fragments: projection.v2Fragments, deviceReceipts: projection.deviceReceipts,
      legacyReceipts: projection.legacyReceipts,
      sourceBytesByKind: ["state": 16 * 1024 * 1024 - 1100, "devices": 1000],
      sourceChunksByKind: ["state": 4089, "devices": 1])
    let plan = try ReadStateV2PublicationBuilder.publication(current: current, projection: nearCap,
      viewerDid: viewer, device: projection.deviceReceipts[0], maintenance: true)
    #expect(plan.stateHead == nil)
    #expect(plan.devicesHead == current.manifest.devicesHead)
    #expect(plan.lastSequence == current.manifest.lastSequence)
    #expect(plan.revision == current.manifest.effectiveRevision + 1)
    #expect(plan.chunks.count == 1)
  }

  @Test func loaderRejectsMissingReceiptsWrongKindsAndUnknownFields() async throws {
    let op = operation("old")
    let fragment = try ReadStateV2Fragment(operation: op, intentHash: ReadStateV2PublicationBuilder.hash([op]))
    let reference = ReadStateReference(uri: "at://\(viewer)/\(ReadStateChunk.collection)/state", cid: "state")
    let manifest = ReadStateManifest(generation: "test", revision: 1, lastSequence: 1, stateHead: reference, devicesHead: nil, legacyReceiptsHead: nil)
    let data = try JSONEncoder().encode(ReadStateV2Chunk(fragments: [fragment]))
    await #expect(throws: ReadStateError.incompleteGeneration) {
      try await ReadStateGenerationLoader.loadRecords(manifest: manifest, viewerDid: viewer) { _ in data }
    }
    let device = try ReadStateDeviceReceipt(viewerDid: viewer, deviceId: UUID().uuidString.lowercased())
    let wrong = try JSONEncoder().encode(ReadStateV2Chunk(devices: [device]))
    await #expect(throws: ReadStateError.invalidRecord) {
      try await ReadStateGenerationLoader.loadRecords(manifest: manifest, viewerDid: viewer) { _ in wrong }
    }
    var raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    raw["futureBehavior"] = true
    let unknown = try JSONSerialization.data(withJSONObject: raw)
    #expect(throws: ReadStateError.invalidRecord) { try JSONDecoder().decode(ReadStateV2Chunk.self, from: unknown) }
    await #expect(throws: ReadStateError.sizeLimit) {
      try await ReadStateGenerationLoader.loadRecords(manifest: manifest, viewerDid: viewer, maximumBytes: 1) { _ in data }
    }
  }

  @Test func largeSelectionsSplitWithoutChangingOriginalIntentHash() async throws {
    let subjects = (0..<128).map { "at://did:plc:author/site.standard.document/\($0)-" + String(repeating: "a", count: 490) }
    let op = ReadStateOperation(actionId: "large", sequence: 1, state: .read, actedAt: "2026-09-08T12:00:00Z", subjectUris: subjects)
    let fixture = V2SyncFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let engine = try ReadStateSyncEngine(viewerDid: viewer, file: url, transport: fixture.transport())
    try await engine.upgradeToV2(); try await engine.enqueue([op]); try await engine.flush()
    let projection = try await fixture.currentProjection()
    #expect(Set(projection.operations.flatMap { $0.subjectUris ?? [] }) == Set(subjects))
    #expect(Set(projection.v2Fragments.map(\.intentHash)) == [try ReadStateV2PublicationBuilder.hash([op])])
    #expect(projection.lastSequence == 1)
    #expect(projection.v2Fragments.count > 1)
  }
}

private actor V2SyncFixture {
  nonisolated let viewer = "did:plc:viewer"
  var record: ReadStateManifestRecord? = .init(manifest: .init(generation: "initial", lastSequence: 0, head: nil), cid: "initial")
  var records: [String: Data] = [:]
  var manifestWrites = 0
  var failConfirmation = false
  var failAfterWrite = false
  var chunkCount: Int { records.count }
  var readsToRace = 0
  var waitingRead: CheckedContinuation<Void, Never>?
  func raceNextReads() { readsToRace = 2 }
  func read() async -> ReadStateManifestRecord? {
    let snapshot = record
    if readsToRace > 0 {
      readsToRace -= 1
      if readsToRace == 1 { await withCheckedContinuation { waitingRead = $0 } }
      else { waitingRead?.resume(); waitingRead = nil }
    }
    return snapshot
  }
  func failConfirmOnce() { failConfirmation = true }
  func failConfirmAfterNextWrite() { failAfterWrite = true }
  nonisolated func transport() -> ReadStateSyncTransport {
    .init(readManifest: { await self.read() }, loadProjection: { try await self.projection($0) },
      putChunk: { try await self.put($0, JSONEncoder().encode($1)) },
      putManifest: { try await self.putManifest($0, expected: $1) },
      confirm: { try await self.confirm($0, revision: $1) },
      putV2Chunk: { try await self.put($0, JSONEncoder().encode($1)) })
  }
  func put(_ key: String, _ data: Data) throws -> ReadStateReference {
    let uri = "at://\(viewer)/\(ReadStateChunk.collection)/\(key)"
    if let old = records[uri] { #expect(try JSONSerialization.jsonObject(with: old) as? NSDictionary == JSONSerialization.jsonObject(with: data) as? NSDictionary) }
    records[uri] = data
    return .init(uri: uri, cid: key)
  }
  func fetch(_ reference: ReadStateReference) throws -> Data {
    guard let data = records[reference.uri] else { throw ReadStateError.incompleteGeneration }; return data
  }
  func projection(_ manifest: ReadStateManifest) async throws -> ReadStateProjection {
    try await ReadStateGenerationLoader.loadRecords(manifest: manifest, viewerDid: viewer) { try await self.fetch($0) }
  }
  func currentProjection() async throws -> ReadStateProjection {
    guard let record else { throw ReadStateError.incompleteGeneration }; return try await projection(record.manifest)
  }
  func putManifest(_ manifest: ReadStateManifest, expected: String?) throws -> String {
    guard record?.cid == expected else { throw ReadStateSyncFailure.conflict }
    manifestWrites += 1
    let cid = "manifest-\(manifestWrites)"; record = .init(manifest: manifest, cid: cid)
    if failAfterWrite { failAfterWrite = false; failConfirmation = true }
    return cid
  }
  func confirm(_ cid: String, revision: Int64?) throws {
    guard cid == record?.cid else { throw ReadStateSyncFailure.conflict }
    if failConfirmation { failConfirmation = false; throw URLError(.networkConnectionLost) }
  }
}
