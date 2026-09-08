import Foundation
import ReadStateCore
import Testing
@testable import ThinAppViewCore

extension PostgresJetstreamInboxIntegrationTests {
  @Test("maintenance preserves projection tuples and evicted state still rebuilds")
  func pdsMaintenancePreservesProjectionAndRebuilds() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let store = fixture.store
      let viewer = "did:plc:" + fixture.sourceGeneration
      let subject = "at://\(viewer)/site.standard.document/one"
      let operation = ReadStateOperation(actionId: "one", sequence: 1, state: .read,
        actedAt: "2026-09-08T00:00:00Z", subjectUris: [subject])
      let root = ReadStateReference(uri: "at://\(viewer)/app.thesocialwire.readStateChunk/a", cid: "chunk")
      let legacy = ReadStateManifest(generation: "v1", lastSequence: 1, head: root)
      _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: legacy, manifestCid: "v1",
        projection: ReadStateProjection(operations: [operation], lastSequence: 1), expectedLegacyRevision: 0)
      let projection = try ReadStateProjection(operations: [operation], lastSequence: 1, protocolVersion: 2)
      let upgraded = ReadStateManifest(generation: "v2", revision: 2, lastSequence: 1,
        stateHead: root, devicesHead: nil, legacyReceiptsHead: nil)
      _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: upgraded, manifestCid: "v2",
        projection: projection, expectedLegacyRevision: nil)
      var tuple: String?
      for try await row in try await fixture.pool.query(
        "SELECT xmin::text FROM appview_pds_read_state_exact WHERE viewer_did = \(viewer)", logger: fixture.logger) {
        tuple = try row.decode(String.self)
      }
      #expect(tuple != nil)
      let maintenance = ReadStateManifest(generation: "v2", revision: 3, lastSequence: 1,
        stateHead: root, devicesHead: nil, legacyReceiptsHead: nil)
      _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: maintenance, manifestCid: "gc",
        projection: projection, expectedLegacyRevision: nil)
      for try await row in try await fixture.pool.query(
        "SELECT xmin::text FROM appview_pds_read_state_exact WHERE viewer_did = \(viewer)", logger: fixture.logger) {
        #expect(try row.decode(String.self) == tuple)
      }
      for try await row in try await fixture.pool.query(
        "SELECT manifest_revision FROM appview_pds_read_state_authority WHERE viewer_did = \(viewer)", logger: fixture.logger) {
        #expect(try row.decode(Int64.self) == 3)
      }
      await #expect(throws: PDSReadStateStorageError.staleGeneration) {
        _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: upgraded, manifestCid: "paused",
          projection: projection, expectedLegacyRevision: nil)
      }
      try await fixture.pool.query(
        "UPDATE appview_pds_read_state_authority SET projection_ready = FALSE WHERE viewer_did = \(viewer)", logger: fixture.logger)
      try await fixture.pool.query(
        "DELETE FROM appview_pds_read_state_exact WHERE viewer_did = \(viewer)", logger: fixture.logger)
      _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: maintenance, manifestCid: "gc",
        projection: projection, expectedLegacyRevision: nil)
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: subject))
      #expect(try await store.pdsReadStateStatus(viewerDid: viewer).projectionReady)
    }
  }
}
