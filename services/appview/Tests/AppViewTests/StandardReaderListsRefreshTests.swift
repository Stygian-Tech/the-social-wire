import Foundation
import Testing

@testable import AppView

@Suite("Standard Reader list refresh fencing")
struct StandardReaderListsRefreshTests {
  @Test("forced refresh discovers created lists and removes deleted own lists and saved references")
  func createdAndDeleted() async throws {
    let reader = MutableListReader()
    let service = StandardReaderListsService(reader: reader)
    let viewer = "did:plc:viewer"
    #expect(try await service.lists(viewerDid: viewer).lists.isEmpty)
    await reader.set(own: true, saved: true)
    let created = try await service.lists(viewerDid: viewer, refresh: true)
    #expect(created.complete)
    #expect(created.lists.map(\.uri) == [MutableListReader.ownURI, MutableListReader.savedURI])
    #expect(created.lists[0].owned && !created.lists[0].saved)
    #expect(!created.lists[1].owned && created.lists[1].saved)
    await reader.set(own: false, saved: true)
    let deleted = try await service.lists(viewerDid: viewer, refresh: true)
    #expect(deleted.lists.map(\.uri) == [MutableListReader.savedURI])
    #expect(deleted.complete)
    await reader.set(own: false, saved: false)
    let removed = try await service.lists(viewerDid: viewer, refresh: true)
    #expect(removed.lists.isEmpty && removed.complete)
    #expect(try await service.lists(viewerDid: viewer).lists.isEmpty)
  }

  @Test("post-write forced refresh cannot join or be overwritten by a pre-write load")
  func forcedRefresh() async throws {
    let reader = RefreshRaceListReader()
    let service = StandardReaderListsService(reader: reader)
    let oldLoad = Task { try await service.lists(viewerDid: "did:plc:viewer") }
    await reader.waitForOldLoad()
    let fresh = try await service.lists(viewerDid: "did:plc:viewer", refresh: true)
    #expect(fresh.lists.first?.name == "After Save")
    await reader.releaseOldLoad()
    let old = try await oldLoad.value
    #expect(old.lists.first?.name == "Before Save")
    let cached = try await service.lists(viewerDid: "did:plc:viewer")
    #expect(cached.lists.first?.name == "After Save")
  }
}

private actor MutableListReader: StandardReaderListReading {
  static let ownURI = "at://did:plc:viewer/app.standard-reader.list/own"
  static let savedURI = "at://did:plc:creator/app.standard-reader.list/shared"
  private var own = false
  private var saved = false

  func set(own: Bool, saved: Bool) { self.own = own; self.saved = saved }

  private func listValue() throws -> Data {
    try JSONSerialization.data(withJSONObject: ["name": "Public News", "publications": [],
      "createdAt": "2026-10-03T05:00:00Z"])
  }

  func records(did: String, collection: String) async throws -> SemblePublicRecordRead {
    let record: SemblePublicRecord?
    if collection == StandardReaderListIdentity.collection {
      record = own ? .init(collection: collection, uri: Self.ownURI, cid: nil, value: try listValue()) : nil
    } else {
      record = saved ? .init(collection: collection,
        uri: "at://did:plc:viewer/app.standard-reader.listSave/arbitrary-key", cid: nil,
        value: try JSONSerialization.data(withJSONObject: ["list": Self.savedURI,
          "createdAt": "2026-10-03T05:00:00Z"])) : nil
    }
    return .init(records: record.map { [$0] } ?? [], complete: true)
  }

  func record(identity: StandardReaderListIdentity) async throws -> Data? {
    identity.uri == Self.savedURI ? try listValue() : nil
  }
  func creatorDid(_ input: String) async throws -> String? { nil }
}

private actor RefreshRaceListReader: StandardReaderListReading {
  private var ownReads = 0
  private var release: CheckedContinuation<Void, Never>?
  private var started: CheckedContinuation<Void, Never>?

  func waitForOldLoad() async {
    if ownReads > 0 { return }
    await withCheckedContinuation { started = $0 }
  }

  func releaseOldLoad() { release?.resume(); release = nil }

  func records(did: String, collection: String) async throws -> SemblePublicRecordRead {
    guard collection == StandardReaderListIdentity.collection else {
      return .init(records: [], complete: true)
    }
    ownReads += 1
    let isOld = ownReads == 1
    if isOld {
      await withCheckedContinuation { continuation in
        release = continuation
        started?.resume()
        started = nil
      }
    }
    let value = try JSONSerialization.data(withJSONObject: [
      "name": isOld ? "Before Save" : "After Save", "publications": [], "createdAt": "2026-10-02T12:00:00Z"
    ])
    return .init(records: [.init(collection: collection,
      uri: "at://did:plc:viewer/app.standard-reader.list/news", cid: nil, value: value)], complete: true)
  }

  func record(identity: StandardReaderListIdentity) async throws -> Data? { nil }
  func creatorDid(_ input: String) async throws -> String? { nil }
}
