import Foundation
import Logging
import ReadStateCore
import Testing
@testable import ThinAppViewCore

@Suite("Verified manifest projection")
struct PDSReadStateProjectorTests {
  @Test func nearLimitRecordDoesNotGrowWhenExtractedFromPDSEnvelope() throws {
    let prefix = "at://did:plc:viewer/site.standard.document/"
    let uris = (0..<32).map { prefix + String(repeating: "a/", count: 980) + String($0) }
    let chunk = ReadStateChunk(operations: [ReadStateOperation(actionId: "near-limit", sequence: 1,
      state: .read, actedAt: "2026-09-08T00:00:00Z", subjectUris: uris)], previous: nil)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = try encoder.encode(chunk)
    #expect(data.count == 64_440)
    let envelope: [String: Any] = [
      "uri": "at://did:plc:viewer/app.thesocialwire.readStateChunk/a",
      "cid": "bafyreib4cw6rmb3qrcyxibmqumt4bd277e7kpl2ojetscnjkmpy7ntch2i",
      "value": try JSONSerialization.jsonObject(with: data),
    ]
    let extracted = try LivePDSReadStateRecordFetcher.record(from:
      JSONSerialization.data(withJSONObject: envelope, options: [.withoutEscapingSlashes]))
    #expect(extracted.json.count == data.count)
    let verified: ReadStateChunk = try extracted.decode(viewerDid: "did:plc:viewer",
      collection: ReadStateChunk.collection, key: "a")
    try ReadStateValidation.validate(verified, viewerDid: "did:plc:viewer")
    #expect(verified.operations.first?.subjectUris == uris)
  }

  @Test func unmigratedViewerDoesNotFetchOrActivate() async throws {
    let store = ProjectionStore(active: false)
    let remote = Records()
    let projector = PDSReadStateProjector(store: store, fetchRecord: { try await remote.fetch(viewerDid: $0, collection: $1, key: $2, cid: $3) })
    #expect(try await projector.reconcile(viewerDid: Records.viewer) == false)
    #expect(await remote.requests == 0)
    #expect(await store.activations == 0)
  }

  @Test func backgroundManifestEventsDoNotRebuildEvictedViewers() async throws {
    let store = ProjectionStore(active: true, ready: false)
    let remote = Records()
    let projector = PDSReadStateProjector(store: store, fetchRecord: {
      try await remote.fetch(viewerDid: $0, collection: $1, key: $2, cid: $3)
    })
    #expect(try await projector.reconcile(viewerDid: Records.viewer, rebuildEvicted: false) == false)
    #expect(await remote.requests == 0)
    #expect(await store.activations == 0)
  }

  @Test func completeCIDVerifiedChainRebuildsAndReusesImmutableChunks() async throws {
    let store = ProjectionStore(active: true)
    let remote = Records()
    let projector = PDSReadStateProjector(store: store, fetchRecord: { try await remote.fetch(viewerDid: $0, collection: $1, key: $2, cid: $3) })
    #expect(try await projector.reconcile(viewerDid: Records.viewer))
    #expect(try await projector.reconcile(viewerDid: Records.viewer))
    #expect(await store.activations == 2)
    #expect(await remote.requests == 5) // Two head reads per rebuild, one immutable chunk fetch.
    #expect(await store.lastProjection?.operations.first?.subjectUris == ["x"])
  }

  @Test(arguments: [Records.Failure.corrupt, .wrongViewer, .missingChunk, .changedHead])
  func invalidOrIncompleteGenerationNeverActivates(failure: Records.Failure) async throws {
    let store = ProjectionStore(active: true)
    let remote = Records(failure: failure)
    let projector = PDSReadStateProjector(store: store, fetchRecord: { try await remote.fetch(viewerDid: $0, collection: $1, key: $2, cid: $3) })
    await #expect(throws: (any Error).self) { try await projector.reconcile(viewerDid: Records.viewer) }
    #expect(await store.activations == 0)
  }

  @Test func unreferencedChunksAndLegacyRecordsAreIgnored() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let logger = Logger(label: "read-state-indexer-test")
    let store = try SQLiteThinAppViewStore(path: path, logger: logger)
    let indexer = ThinAppViewIndexer(store: store,
      config: ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"]), logger: logger)
    for collection in [ReadStateChunk.collection, "app.thesocialwire.entryReadState", "com.thesocialwire.entryReadState"] {
      let outcome = try await indexer.handleCommitWithOutcome(repoDid: Records.viewer,
        collection: collection, rkey: "a", cid: "invalid", recordJSON: Data("{}".utf8), operation: "create")
      #expect(outcome == .skipped)
      #expect(!AppViewIngestionScopePolicy.viewerCollections.contains(collection))
    }
    #expect(AppViewIngestionScopePolicy.viewerCollections.contains(ReadStateManifest.collection))
  }

  private actor ProjectionStore: PDSReadStateStoring {
    let active: Bool
    let ready: Bool
    var activations = 0
    var lastProjection: ReadStateProjection?
    init(active: Bool, ready: Bool = true) { self.active = active; self.ready = ready }
    func pdsReadStateStatus(viewerDid: String) -> PDSReadStateStatus {
      PDSReadStateStatus(authority: active ? .pds : .appview,
        migrationState: active ? .verified : .notStarted, legacyRevision: 0, projectionReady: ready)
    }
    func activatePDSReadState(viewerDid: String, manifest: ReadStateManifest, manifestCid: String,
      projection: ReadStateProjection, expectedLegacyRevision: Int64?) -> PDSReadStateStatus {
      activations += 1
      lastProjection = projection
      return pdsReadStateStatus(viewerDid: viewerDid)
    }
    func exportPDSReadStatePage(viewerDid: String, cursor: String?, expectedLegacyRevision: Int64?, limit: Int) throws -> PDSReadStateExportPage {
      throw ReadStateError.invalidRecord
    }
    func previewPDSReadStateBoundaries(viewerDid: String, boundaries: [ReadStateBoundary], subjectUris: [String]) throws -> [String] {
      throw ReadStateError.invalidRecord
    }
    func preparePDSReadStateBoundaries(viewerDid: String, scopes: [PublicationUnreadScope], at: Date) throws -> [ReadStateBoundary] {
      throw ReadStateError.invalidRecord
    }
  }

  actor Records {
    enum Failure: Sendable { case corrupt, wrongViewer, missingChunk, changedHead }
    static let viewer = "did:plc:viewer"
    // Independently generated by @atproto/lex-cbor cidForLex.
    static let chunkCID = "bafyreihla6hxlrs3uokhllzvd4wh2up6uhla3aws4lkeyis37qgfllk3vq"
    static let manifestCID = "bafyreigmr7av5znixd77djvb5gdjduclguqjccb7owm6p75ifoce4vksjq"
    static let chunk = #"{"$type":"app.thesocialwire.readStateChunk","version":1,"operations":[{"actionId":"one","sequence":1,"state":"read","actedAt":"2026-09-08T00:00:00Z","selection":"exact","subjectUris":["x"]}]}"#
    static let manifest = #"{"$type":"app.thesocialwire.readState","version":1,"generation":"test","lastSequence":1,"head":{"uri":"at://did:plc:viewer/app.thesocialwire.readStateChunk/a","cid":"bafyreihla6hxlrs3uokhllzvd4wh2up6uhla3aws4lkeyis37qgfllk3vq"}}"#
    let failure: Failure?
    var requests = 0
    init(failure: Failure? = nil) { self.failure = failure }
    func fetch(viewerDid: String, collection: String, key: String, cid: String?) throws -> PDSReadStateFetchedRecord {
      requests += 1
      let isChunk = collection == ReadStateChunk.collection
      if isChunk && failure == .missingChunk { throw ReadStateError.incompleteGeneration }
      var json = isChunk ? Self.chunk : Self.manifest
      if failure == .corrupt { json = json.replacingOccurrences(of: "test", with: "tampered") }
      return PDSReadStateFetchedRecord(
        uri: "at://\(failure == .wrongViewer ? "did:plc:other" : viewerDid)/\(collection)/\(key)",
        cid: failure == .changedHead && requests > 2 ? "changed" : (isChunk ? Self.chunkCID : Self.manifestCID),
        json: Data(json.utf8))
    }
  }
}
