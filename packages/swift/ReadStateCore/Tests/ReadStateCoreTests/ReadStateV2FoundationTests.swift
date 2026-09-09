import Foundation
import Testing
@testable import ReadStateCore

@Suite struct ReadStateV2FoundationTests {
  private struct Fixture: Decodable {
    let viewerDid: String
    let deviceId: String
    let manifest: ReadStateManifest
    let operations: [ReadStateOperation]
    let compactedOperations: [ReadStateOperation]
    let receipts: [ReadStateLegacyActionReceipt]
    let initialReceipt: ReadStateDeviceReceipt
    let advancedReceipt: ReadStateDeviceReceipt
  }
  private func fixture() throws -> Fixture {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("read-state/fixtures/v2-foundation.json")))
  }
  @Test func sharedVectorsPreserveWholeIntentHashesAndOriginalMetadata() throws {
    let f = try fixture()
    let source = try ReadStateProjection(operations: f.operations, lastSequence: 9)
    let manifest = try JSONEncoder().encode(f.manifest)
    let compact = try ReadStateSemanticCompactor.compact(source, manifestJSON: manifest, viewerDid: f.viewerDid)
    #expect(compact.operations == f.compactedOperations)
    #expect(compact.receipts == f.receipts)
    #expect(compact.operations.map(\.sequence) == [1,2,3,6,7,8,9])
    let reversed = try ReadStateSemanticCompactor.compact(ReadStateProjection(operations: f.operations.reversed(), lastSequence: 9), manifestJSON: manifest, viewerDid: f.viewerDid)
    #expect(reversed.operations == compact.operations)
    #expect(reversed.receipts == compact.receipts)
    let receipt = try ReadStateDeviceReceipt(viewerDid: f.viewerDid, deviceId: f.deviceId)
    #expect(receipt == f.initialReceipt)
    let hashes = compact.receipts.map(\.originalIntentHash)
    #expect(try receipt.advancing(firstCounter: 1, intentHashes: hashes) == f.advancedReceipt)
    #expect(try receipt.verifiedAcknowledgement(f.advancedReceipt, pendingIntentHashes: hashes) == 9)
    #expect(throws: ReadStateError.conflictingSequence) { try receipt.verifiedAcknowledgement(f.advancedReceipt, pendingIntentHashes: Array(hashes.dropFirst())) }
    #expect(throws: ReadStateError.conflictingSequence) { try receipt.verifiedAcknowledgement(f.advancedReceipt, pendingIntentHashes: Array(repeating: String(repeating: "0", count: 64), count: 9)) }
    #expect(throws: ReadStateError.conflictingSequence) { try receipt.advancing(firstCounter: 2, intentHashes: hashes) }
    #expect(throws: ReadStateError.invalidRecord) { try ReadStateDeviceReceipt(viewerDid: f.viewerDid, deviceId: "not-a-device") }
    let first = f.operations[0]
    let parts = [["é"], ["𐀀", "a"]].map { ReadStateOperation(actionId: first.actionId, sequence: first.sequence,
      state: first.state, actedAt: first.actedAt, subjectUris: $0, calendar: first.calendar) }
    #expect(try ReadStateSemanticCompactor.originalIntentHash(partsJSON: JSONEncoder().encode(parts)) == hashes[0])
    let renumbered = ReadStateOperation(actionId: first.actionId, sequence: 99, state: first.state,
      actedAt: first.actedAt, subjectUris: first.subjectUris!, calendar: first.calendar)
    #expect(try ReadStateSemanticCompactor.originalIntentHash(partsJSON: JSONEncoder().encode([renumbered])) == hashes[0])
  }
  @Test func unknownSourceSemanticsAndSubmicrosecondBoundariesAreNotRewritten() throws {
    let f = try fixture()
    let manifest = try JSONEncoder().encode(f.manifest)
    let source = try ReadStateProjection(operations: f.operations, lastSequence: 9, allowsRepacking: false)
    #expect(throws: ReadStateError.invalidRecord) { try ReadStateSemanticCompactor.compact(source, manifestJSON: manifest, viewerDid: f.viewerDid) }
    var raw = try #require(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
    raw["extra"] = true
    #expect(throws: ReadStateError.invalidRecord) { try ReadStateSemanticCompactor.compact(ReadStateProjection(operations: f.operations, lastSequence: 9), manifestJSON: JSONSerialization.data(withJSONObject: raw), viewerDid: f.viewerDid) }
    var parts = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode([f.operations[0]])) as? [[String: Any]])
    parts[0]["extra"] = true
    #expect(throws: ReadStateError.invalidRecord) { try ReadStateSemanticCompactor.originalIntentHash(partsJSON: JSONSerialization.data(withJSONObject: parts)) }
    let old = f.operations[2], boundary = old.boundaries![0]
    var ops = f.operations
    ops[2] = .init(actionId: old.actionId, sequence: old.sequence, state: old.state, actedAt: old.actedAt,
      boundaries: [.init(scope: boundary.scope, createdAt: "2026-11-01T06:30:00.000000001Z", entryId: nil)])
    #expect(throws: ReadStateError.invalidRecord) { try ReadStateSemanticCompactor.compact(ReadStateProjection(operations: ops, lastSequence: 9), manifestJSON: manifest, viewerDid: f.viewerDid) }
  }
  @Test func seededHistoriesPreserveEveryResolverFieldForUnseenBackfills() throws {
    let f = try fixture()
    var seed: UInt32 = 1234
    func random() -> UInt32 { seed = seed &* 1664525 &+ 1013904223; return seed }
    let uris = ["a", "z", "é", "𐀀", "late"]
    for trial in 0..<24 {
      var operations: [ReadStateOperation] = []
      for sequence in 1...48 {
        let actionId = "\(trial)-\(sequence)"
        let state: ReadStateOperation.State = random() % 2 == 1 ? .read : .unread
        let actedAt = sequence % 2 == 1 ? "2026-11-01T01:30:00-05:00" : "2026-11-01T01:30:00-04:00"
        if random() % 3 == 0 {
          operations.append(.init(actionId: actionId, sequence: Int64(sequence), state: state, actedAt: actedAt, subjectUris: [uris[Int(random() % 4)]]))
        } else {
          let publicationId = "p\(random() % 2)"
          let keys = random() % 2 == 1 ? ["site"] : []
          let createdAt = String(format: "2026-11-01T06:30:00.%06uZ", random() % 20)
          let entryId = random() % 2 == 1 ? uris[Int(random() % 4)] : nil
          operations.append(.init(actionId: actionId, sequence: Int64(sequence), state: state, actedAt: actedAt,
            boundaries: [.init(scope: .init(publicationId: publicationId, authorDid: "did:plc:writer", publicationSiteKeys: keys), createdAt: createdAt, entryId: entryId)]))
        }
      }
      let manifest = ReadStateManifest(generation: "property", lastSequence: 48, head: f.manifest.head)
      let before = try ReadStateProjection(operations: operations, lastSequence: 48)
      let compact = try ReadStateSemanticCompactor.compact(before, manifestJSON: JSONEncoder().encode(manifest), viewerDid: f.viewerDid)
      let after = try ReadStateProjection(operations: compact.operations, lastSequence: 48)
      for uri in uris { for micro in [0,5,10,19,20] { for site in ["site", "unseen"] {
        let subject = ReadStateSubject(uri: uri, authorDid: "did:plc:writer", publicationSite: site,
          createdAt: try ReadStateValidation.date(String(format: "2026-11-01T06:30:00.%06dZ", micro)))
        #expect(after.resolve(subject) == before.resolve(subject))
      } } }
      let reversed = try ReadStateSemanticCompactor.compact(ReadStateProjection(operations: operations.reversed(), lastSequence: 48), manifestJSON: JSONEncoder().encode(manifest), viewerDid: f.viewerDid)
      #expect(reversed.operations == compact.operations)
      #expect(reversed.receipts == compact.receipts)
    }
  }
}
