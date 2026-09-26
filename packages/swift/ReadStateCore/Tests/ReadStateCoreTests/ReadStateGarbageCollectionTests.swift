import Foundation
import Testing
@testable import ReadStateCore

@Suite struct ReadStateGarbageCollectionTests {
  let viewer = "did:plc:viewer"
  let start = Date(timeIntervalSince1970: 1_000_000)
  let uptime: TimeInterval = 100_000
  let day: TimeInterval = 86_400
  func file() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/gc.json") }

  @Test func disabledByDefaultAndMissingProofNeverDeletes() async throws {
    let fixture = GCFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let disabled = try ReadStateGarbageCollectionEngine(viewerDid: viewer, file: url, transport: fixture.transport())
    #expect(try await disabled.run() == .disabled)
    #expect(await fixture.snapshotCalls == 0)
    let noTransport = try ReadStateGarbageCollectionEngine(viewerDid: viewer, file: url, enabled: true)
    await #expect(throws: ReadStateGarbageCollectionEngine.Failure.proofUnavailable) { try await noTransport.run() }
    #expect(await fixture.applies == 0)
  }

  @Test func observedGraceAndEveryReachableRootAreProtected() async throws {
    let fixture = GCFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    await fixture.add("old"); await fixture.add("state"); await fixture.add("devices"); await fixture.add("legacy"); await fixture.add("child")
    await fixture.protectRoots()
    let engine = try ReadStateGarbageCollectionEngine(viewerDid: viewer, file: url, enabled: true, transport: fixture.transport())
    #expect(try await engine.run(now: start, uptime: uptime) == .observed(1))
    #expect(try await engine.run(now: start.addingTimeInterval(day - 1), uptime: uptime + day - 1) == .observed(1))
    #expect(await fixture.applies == 0)
    #expect(try await engine.run(now: start.addingTimeInterval(day), uptime: uptime + day) == .collected(1))
    #expect(await fixture.keys == ["state", "devices", "legacy", "child"])
    let batch = try #require(await fixture.lastBatch)
    #expect(batch.manifest.lastSequence == 0)
    #expect(batch.manifest.revision == 2)
    #expect(batch.manifest.stateHead != nil && batch.manifest.devicesHead != nil && batch.manifest.legacyReceiptsHead != nil)
  }

  @Test func clockJumpResetsGrace() async throws {
    let fixture = GCFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    await fixture.add("old")
    let engine = try ReadStateGarbageCollectionEngine(viewerDid: viewer, file: url, enabled: true, transport: fixture.transport())
    _ = try await engine.run(now: start, uptime: uptime)
    #expect(try await engine.run(now: start.addingTimeInterval(day * 2), uptime: uptime + 1) == .observed(1))
    #expect(await fixture.applies == 0)
    #expect(try await engine.run(now: start.addingTimeInterval(day * 3), uptime: uptime + 1 + day) == .collected(1))
  }

  @Test func garbageCollectionFencesPausedWriterManifestCAS() async throws {
    let fixture = GCFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    await fixture.add("paused")
    let oldCid = await fixture.record.cid
    let engine = try ReadStateGarbageCollectionEngine(viewerDid: viewer, file: url, enabled: true, transport: fixture.transport())
    _ = try await engine.run(now: start, uptime: uptime)
    _ = try await engine.run(now: start.addingTimeInterval(day), uptime: uptime + day)
    await #expect(throws: ReadStateSyncFailure.self) { try await fixture.publishPaused(expectedCid: oldCid, key: "paused") }
    #expect(await fixture.keys.isEmpty)
    #expect(await fixture.record.manifest.effectiveRevision == 2)
  }

  @Test func writerWinningFirstMakesDeleteTransactionFailAtomically() async throws {
    let fixture = GCFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    await fixture.add("paused")
    let engine = try ReadStateGarbageCollectionEngine(viewerDid: viewer, file: url, enabled: true, transport: fixture.transport())
    _ = try await engine.run(now: start, uptime: uptime)
    await fixture.raceWriter()
    await #expect(throws: ReadStateSyncFailure.self) {
      try await engine.run(now: start.addingTimeInterval(day), uptime: uptime + day)
    }
    #expect(await fixture.keys == ["paused"])
    #expect(try await engine.run(now: start.addingTimeInterval(day + 1), uptime: uptime + day + 1) == .observed(0))
    #expect(await fixture.keys == ["paused"])
  }

  @Test func ambiguousSuccessIsVerifiedAfterRestartAndNotResent() async throws {
    let fixture = GCFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    await fixture.add("old")
    let engine = try ReadStateGarbageCollectionEngine(viewerDid: viewer, file: url, enabled: true, transport: fixture.transport())
    _ = try await engine.run(now: start, uptime: uptime)
    await fixture.loseResponse()
    await #expect(throws: URLError.self) {
      try await engine.run(now: start.addingTimeInterval(day), uptime: uptime + day)
    }
    #expect(await fixture.applies == 1)
    let resumed = try ReadStateGarbageCollectionEngine(viewerDid: viewer, file: url, enabled: true, transport: fixture.transport())
    #expect(try await resumed.run(now: start.addingTimeInterval(day + 1), uptime: uptime + day + 1) == .collected(1))
    #expect(await fixture.applies == 1)
  }

  @Test func authorityConfirmationIsRequiredBeforeAndAfterCollection() async throws {
    let fixture = GCFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    await fixture.add("old")
    let engine = try ReadStateGarbageCollectionEngine(viewerDid: viewer, file: url, enabled: true, transport: fixture.transport())
    _ = try await engine.run(now: start, uptime: uptime)
    await fixture.failConfirm()
    await #expect(throws: URLError.self) { try await engine.run(now: start.addingTimeInterval(day), uptime: uptime + day) }
    #expect(await fixture.applies == 0)
    await fixture.failConfirmAfterApply()
    await #expect(throws: URLError.self) { try await engine.run(now: start.addingTimeInterval(day), uptime: uptime + day) }
    #expect(await fixture.applies == 1)
    let resumed = try ReadStateGarbageCollectionEngine(viewerDid: viewer, file: url, enabled: true, transport: fixture.transport())
    #expect(try await resumed.run(now: start.addingTimeInterval(day + 1), uptime: uptime + day + 1) == .collected(1))
    #expect(await fixture.applies == 1)
  }

  @Test func changedCandidateAndUnverifiableProofAreNeverDeleted() async throws {
    let fixture = GCFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    await fixture.add("changed"); await fixture.add("unreadable"); await fixture.add("no-proof"); await fixture.addUnknown()
    let engine = try ReadStateGarbageCollectionEngine(viewerDid: viewer, file: url, enabled: true, transport: fixture.transport())
    _ = try await engine.run(now: start, uptime: uptime)
    await fixture.setBadProofs()
    #expect(try await engine.run(now: start.addingTimeInterval(day), uptime: uptime + day) == .observed(0))
    #expect(await fixture.applies == 0)
    #expect(await fixture.keys.count == 4)
  }

  @Test func batchesHaveAtMostOneHundredDeletesAndOwnershipFenceSurvivesRefactor() async throws {
    let fixture = GCFixture(); let url = file()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    for index in 0..<110 { await fixture.add("old-\(index)") }
    let old = try ReadStateGarbageCollectionEngine(viewerDid: viewer, file: url, enabled: true, transport: fixture.transport())
    _ = try await old.run(now: start, uptime: uptime)
    let resumed = try ReadStateGarbageCollectionEngine(viewerDid: viewer, file: url, enabled: true, transport: fixture.transport())
    await #expect(throws: ReadStateSyncFailure.self) { try await old.run(now: start.addingTimeInterval(day), uptime: uptime + day) }
    #expect(await fixture.applies == 0)
    #expect(try await resumed.run(now: start.addingTimeInterval(day), uptime: uptime + day) == .collected(100))
    let batch = try #require(await fixture.lastBatch)
    let wire = try #require(JSONSerialization.jsonObject(with: batch.applyWritesJSON()) as? [String: Any])
    #expect((wire["writes"] as? [Any])?.count == 101)
    #expect(wire["swapCommit"] as? String == batch.swapCommit)
    #expect(await fixture.keys.count == 10)
  }
}

/// Models an atomic conforming PDS; does not claim to test a real CAR verifier.
private actor GCFixture {
  nonisolated let viewer = "did:plc:viewer"
  nonisolated let contentCid = "bafyreidzjnajec3km6qosuro4cjahfqluinaxbxhpwihratxt7e3yqgvhm"
  nonisolated let chunkJSON = Data(#"{"$type":"app.thesocialwire.readStateChunk","version":1,"operations":[{"actionId":"orphan","sequence":1,"state":"read","actedAt":"2026-09-08T12:00:00Z","selection":"exact","subjectUris":["at://did:plc:author/site.standard.document/story"]}]}"#.utf8)
  nonisolated let unknownJSON = Data(#"{"$type":"app.thesocialwire.readStateChunk","version":1,"operations":[{"actionId":"orphan","sequence":1,"state":"read","actedAt":"2026-09-08T12:00:00Z","selection":"exact","subjectUris":["at://did:plc:author/site.standard.document/story"]}],"futureRoot":{"uri":"at://did:plc:viewer/app.thesocialwire.readStateChunk/protected","cid":"other"}}"#.utf8)
  func addUnknown() { references["unknown"] = .init(uri: "at://\(viewer)/\(ReadStateChunk.collection)/unknown", cid: "bafyreigj76munsblmwf5jold6xcn7pjafqtitdtcks32ajamoyqsjitmzi") }
  var record = ReadStateManifestRecord(manifest: .init(generation: "initial", revision: 1, lastSequence: 0,
    stateHead: nil, devicesHead: nil, legacyReceiptsHead: nil), cid: "manifest-1")
  var commit = "repo-1"
  var references: [String: ReadStateReference] = [:]
  var sources: Set<ReadStateReference> = []
  var applies = 0
  var snapshotCalls = 0
  var lastBatch: ReadStateGarbageCollectionBatch?
  var writerRace = false
  var responseLoss = false
  var badProofs = false
  var confirmationFailure = false
  var confirmationAfterApply = false
  func failConfirm() { confirmationFailure = true }
  func failConfirmAfterApply() { confirmationAfterApply = true }
  func confirm(_ cid: String) throws {
    guard cid == record.cid else { throw ReadStateSyncFailure.conflict }
    if confirmationFailure { confirmationFailure = false; throw URLError(.cannotConnectToHost) }
  }
  var keys: Set<String> { Set(references.keys) }
  func add(_ key: String) { references[key] = .init(uri: "at://\(viewer)/\(ReadStateChunk.collection)/\(key)", cid: contentCid) }
  func raceWriter() { writerRace = true }
  func loseResponse() { responseLoss = true }
  func setBadProofs() { badProofs = true }
  func protectRoots() {
    sources = Set(["state", "devices", "legacy", "child"].compactMap { references[$0] })
    record = .init(manifest: .init(generation: "initial", revision: 1, lastSequence: 0,
      stateHead: references["state"], devicesHead: references["devices"], legacyReceiptsHead: references["legacy"]), cid: record.cid)
  }
  nonisolated func transport() -> ReadStateGarbageCollectionTransport {
    .init(verifiedSnapshot: { try await self.snapshot() }, confirmGeneration: { try await self.confirm($0) }, listChunks: { await self.list($0, limit: $1) },
      verifiedChunk: { try await self.proof($0, commit: $1) }, applyAtomic: { try await self.apply($0) })
  }
  func snapshot() throws -> ReadStateGarbageCollectionTransport.Snapshot {
    snapshotCalls += 1
    return .init(viewerDid: viewer, repositoryCommitCid: commit, record: record,
      projection: try .init(operations: [], lastSequence: 0, sourceReferences: sources, protocolVersion: 2))
  }
  func list(_ cursor: String?, limit: Int) -> ReadStateGarbageCollectionTransport.Page {
    .init(references: Array(references.values.sorted { $0.uri < $1.uri }.prefix(limit)), cursor: nil)
  }
  func proof(_ reference: ReadStateReference, commit expected: String) throws -> ReadStateGarbageCollectionTransport.ChunkProof? {
    guard commit == expected else { throw ReadStateGarbageCollectionEngine.Failure.changedSnapshot }
    let key = reference.uri.split(separator: "/").last.map(String.init) ?? ""
    guard references[key] == reference else { return nil }
    if badProofs && key == "no-proof" { return nil }
    return .init(viewerDid: viewer, repositoryCommitCid: commit,
      reference: badProofs && key == "changed" ? .init(uri: reference.uri, cid: "new-cid") : reference,
      json: key == "unknown" ? unknownJSON : (badProofs && key == "unreadable" ? Data("{}".utf8) : chunkJSON))
  }
  func publishPaused(expectedCid: String, key: String) throws {
    guard record.cid == expectedCid else { throw ReadStateSyncFailure.conflict }
    guard let reference = references[key] else { throw ReadStateError.incompleteGeneration }
    sources.insert(reference)
    let next = record.manifest.effectiveRevision + 1
    record = .init(manifest: .init(generation: "writer", revision: next, lastSequence: 0,
      stateHead: reference, devicesHead: nil, legacyReceiptsHead: nil), cid: "manifest-\(next)")
    commit = "repo-\(next)"
  }
  func apply(_ batch: ReadStateGarbageCollectionBatch) throws -> ReadStateGarbageCollectionTransport.Commit {
    if writerRace { writerRace = false; try publishPaused(expectedCid: record.cid, key: "paused") }
    guard batch.swapCommit == commit, batch.previousManifestCid == record.cid else { throw ReadStateSyncFailure.conflict }
    // All membership conditions and CAS pass before any deletion is applied.
    for reference in batch.deletions {
      let key = String(reference.uri.split(separator: "/").last!)
      guard references[key] == reference else { throw ReadStateSyncFailure.conflict }
    }
    applies += 1; lastBatch = batch
    for reference in batch.deletions { references.removeValue(forKey: String(reference.uri.split(separator: "/").last!)) }
    record = .init(manifest: batch.manifest, cid: "gc-manifest-\(applies)")
    commit = "gc-repo-\(applies)"
    if confirmationAfterApply { confirmationAfterApply = false; confirmationFailure = true }
    if responseLoss { responseLoss = false; throw URLError(.networkConnectionLost) }
    return .init(repositoryCommitCid: commit, manifestCid: record.cid)
  }
}
