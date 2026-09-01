import Foundation
import HTTPTypes
import Testing

@testable import AppView

@Suite("Semble projection")
struct SembleProjectionTests {
  private let viewerDid = "did:plc:viewer"
  private let collectionUri = "at://did:plc:viewer/network.cosmik.collection/3collection"
  private let cardUri = "at://did:plc:viewer/network.cosmik.card/3card"

  @Test("configuration defaults to the public Semble projection and supports an override")
  func configuration() {
    #expect(SembleProjectionConfig.fromEnvironment([:]).baseURL == "https://api.semble.so/api")
    #expect(
      SembleProjectionConfig.fromEnvironment([
        "SEMBLE_PUBLIC_API_BASE_URL": "https://api.semble.test/xrpc/"
      ]).baseURL == "https://api.semble.test/xrpc"
    )
  }

  @Test("opaque cursors and collection AT URIs validate fail closed")
  func cursorAndAtUri() {
    let cursor = SembleCursor.encode(nextPage: 3)
    #expect(cursor != nil)
    #expect(SembleCursor.decode(cursor) == 3)
    #expect(SembleCursor.decode("not-a-cursor") == nil)
    #expect(SembleAtUri.parse(collectionUri)?.did == viewerDid)
    #expect(SembleAtUri.parse("https://example.com") == nil)
  }

  @Test("viewer collection listing normalizes metadata and pagination")
  func collections() async throws {
    let service = SembleProjectionService(
      transport: FixtureSembleTransport(responses: [
        "/network.cosmik.collection.listByUser": .ok(
          """
          {
            "collections": [{
              "id": "collection-id",
              "uri": "\(collectionUri)",
              "name": "Read Later",
              "description": "Saved research",
              "accessType": "CLOSED",
              "cardCount": 12,
              "createdAt": "2026-08-01T00:00:00.000Z",
              "updatedAt": "2026-08-29T00:00:00.000Z",
              "author": {"id": "\(viewerDid)", "name": "Viewer", "handle": "viewer.test"}
            }],
            "pagination": {"currentPage": 1, "hasMore": true}
          }
          """
        )
      ]),
      recordReader: FixtureSembleRecordReader(read: .init(records: [], complete: true))
    )
    let response = try await service.collections(viewerDid: viewerDid, cursor: nil, limit: 25)
    #expect(response.collections == [
      SembleCollectionDTO(
        uri: collectionUri,
        name: "Read Later",
        description: "Saved research",
        accessType: "CLOSED",
        cardCount: 12,
        createdAt: "2026-08-01T00:00:00.000Z",
        updatedAt: "2026-08-29T00:00:00.000Z"
      )
    ])
    #expect(SembleCursor.decode(response.cursor) == 2)
  }

  @Test("collection pages preserve rich projection fields and proven public PDS record links")
  func richCollectionPage() async throws {
    let linkUri = "at://did:plc:viewer/network.cosmik.collectionLink/3link"
    let noteUri = "at://did:plc:viewer/network.cosmik.card/3note"
    let records = [
      FixtureSembleRecordReader.record(
        collection: "network.cosmik.collectionLink",
        uri: linkUri,
        cid: "bafylink",
        json: """
        {"collection":{"uri":"\(collectionUri)","cid":"bafycollection"},"card":{"uri":"\(cardUri)","cid":"bafycard"},"addedBy":"\(viewerDid)","addedAt":"2026-08-29T01:00:00.000Z"}
        """
      ),
      FixtureSembleRecordReader.record(
        collection: "network.cosmik.card",
        uri: cardUri,
        cid: "bafycard",
        json: """
        {"type":"URL","content":{"url":"https://example.com"}}
        """
      ),
      FixtureSembleRecordReader.record(
        collection: "network.cosmik.card",
        uri: noteUri,
        cid: "bafynote",
        json: """
        {"type":"NOTE","content":{"text":"Worth reading"},"parentCard":{"uri":"\(cardUri)","cid":"bafycard"}}
        """
      ),
    ]
    let service = SembleProjectionService(
      transport: FixtureSembleTransport(responses: [
        "/network.cosmik.collection.getByAtUri": .ok(collectionFixture())
      ]),
      recordReader: FixtureSembleRecordReader(read: .init(records: records, complete: true))
    )
    let response = try await service.collection(
      viewerDid: viewerDid,
      collectionUri: collectionUri,
      cursor: nil,
      limit: 20
    )
    #expect(response.membershipComplete)
    #expect(response.recordLinksComplete)
    #expect(response.items.count == 1)
    #expect(response.items[0].cardCid == "bafycard")
    #expect(response.items[0].title == "Example title")
    #expect(response.items[0].membership?.linkUri == linkUri)
    #expect(response.items[0].membership?.viewerOwned == true)
    #expect(response.items[0].unlinkAvailable)
    #expect(response.items[0].note?.uri == noteUri)
    #expect(response.items[0].note?.editable == true)
  }

  @Test("partial PDS enrichment retains Semble cards but disables unlink and edit")
  func partialEnrichment() async throws {
    let service = SembleProjectionService(
      transport: FixtureSembleTransport(responses: [
        "/network.cosmik.collection.getByAtUri": .ok(collectionFixture())
      ]),
      recordReader: FixtureSembleRecordReader(read: .init(records: [], complete: false))
    )
    let response = try await service.collection(
      viewerDid: viewerDid,
      collectionUri: collectionUri,
      cursor: nil,
      limit: 20
    )
    #expect(!response.membershipComplete)
    #expect(!response.recordLinksComplete)
    #expect(response.items[0].membership == nil)
    #expect(!response.items[0].unlinkAvailable)
    #expect(response.items[0].note?.text == "Worth reading")
    #expect(response.items[0].note?.uri == nil)
    #expect(response.items[0].note?.editable == false)
  }

  @Test("viewer PDS membership is proven for a card authored by another contributor")
  func viewerMembershipForExternalCard() async throws {
    let contributorDid = "did:plc:contributor"
    let contributorCardUri = "at://\(contributorDid)/network.cosmik.card/external"
    let linkUri = "at://\(viewerDid)/network.cosmik.collectionLink/external"
    let reader = FixtureSembleRecordsByDidReader(reads: [
      viewerDid: .init(records: [
        FixtureSembleRecordReader.record(
          collection: "network.cosmik.collectionLink",
          uri: linkUri,
          cid: "bafylink",
          json: """
          {"collection":{"uri":"\(collectionUri)","cid":"bafycollection"},"card":{"uri":"\(contributorCardUri)","cid":"bafycard"},"addedBy":"\(viewerDid)"}
          """
        )
      ], complete: true),
      contributorDid: .init(records: [], complete: true),
    ])
    let service = SembleProjectionService(
      transport: FixtureSembleTransport(responses: [
        "/network.cosmik.collection.getByAtUri": .ok(
          """
          {
            "id":"collection-id","uri":"\(collectionUri)","name":"Read Later","accessType":"CLOSED",
            "author":{"id":"\(viewerDid)","name":"Viewer","handle":"viewer.test"},
            "urlCards":[{"id":"card-id","type":"URL","url":"https://example.com/article","uri":"\(contributorCardUri)","cardContent":{"url":"https://example.com/article","title":"External"},"createdAt":"2026-08-29T00:00:00.000Z","author":{"id":"\(contributorDid)","name":"Contributor","handle":"contributor.test"}}],
            "cardCount":1,"pagination":{"currentPage":1,"hasMore":false}
          }
          """
        )
      ]),
      recordReader: reader
    )
    let response = try await service.collection(
      viewerDid: viewerDid,
      collectionUri: collectionUri,
      cursor: nil,
      limit: 20
    )
    #expect(response.items[0].membership?.linkUri == linkUri)
    #expect(response.items[0].membership?.viewerOwned == true)
    #expect(response.items[0].contributor.did == contributorDid)
  }

  @Test("owner mismatch is forbidden before projection")
  func ownerMismatch() async {
    let service = SembleProjectionService(
      transport: FixtureSembleTransport(responses: [:]),
      recordReader: FixtureSembleRecordReader(read: .init(records: [], complete: true))
    )
    await #expect(throws: SembleProjectionError.self) {
      _ = try await service.collection(
        viewerDid: viewerDid,
        collectionUri: "at://did:plc:other/network.cosmik.collection/3collection",
        cursor: nil,
        limit: 20
      )
    }
  }

  @Test("connections retain public data and use proven PDS URIs for editability")
  func connections() async throws {
    let connectionUri = "at://did:plc:viewer/network.cosmik.connection/3connection"
    let source = "https://example.com/source"
    let target = "https://example.com/target"
    let service = SembleProjectionService(
      transport: FixtureSembleTransport(responses: [
        "/network.cosmik.connection.getForUrl": .ok(
          """
          {
            "connections": [{
              "connection": {"id":"connection-id","type":"SUPPORTS","note":"Evidence","createdAt":"2026-08-29T00:00:00.000Z","updatedAt":"2026-08-29T00:00:00.000Z","curator":{"id":"\(viewerDid)","name":"Viewer","handle":"viewer.test"}},
              "source": {"url":"\(source)"},
              "target": {"url":"\(target)"}
            }],
            "pagination": {"currentPage":1,"hasMore":false}
          }
          """
        )
      ]),
      recordReader: FixtureSembleRecordReader(read: .init(records: [
        FixtureSembleRecordReader.record(
          collection: "network.cosmik.connection",
          uri: connectionUri,
          cid: "bafyconnection",
          json: """
          {"source":"\(source)","target":"\(target)","connectionType":"SUPPORTS","note":"Evidence"}
          """
        )
      ], complete: true))
    )
    let response = try await service.connections(
      viewerDid: viewerDid,
      url: source,
      cursor: nil,
      limit: 20
    )
    #expect(response.recordLinksComplete)
    #expect(response.connections[0].uri == connectionUri)
    #expect(response.connections[0].editable)
    #expect(response.connections[0].connectionType == "SUPPORTS")
  }

  @Test("connections never trust an unproven projection URI")
  func unprovenConnectionUri() async throws {
    let projectedUri = "at://did:plc:viewer/network.cosmik.connection/unproven"
    let source = "https://example.com/source"
    let target = "https://example.com/target"
    let service = SembleProjectionService(
      transport: FixtureSembleTransport(responses: [
        "/network.cosmik.connection.getForUrl": .ok(
          """
          {
            "connections": [{
              "connection": {"id":"connection-id","uri":"\(projectedUri)","type":"SUPPORTS","createdAt":"2026-08-29T00:00:00.000Z","updatedAt":"2026-08-29T00:00:00.000Z","curator":{"id":"\(viewerDid)","name":"Viewer","handle":"viewer.test"}},
              "source": {"url":"\(source)"},
              "target": {"url":"\(target)"}
            }],
            "pagination": {"currentPage":1,"hasMore":false}
          }
          """
        )
      ]),
      recordReader: FixtureSembleRecordReader(read: .init(records: [], complete: true))
    )
    let response = try await service.connections(
      viewerDid: viewerDid,
      url: source,
      cursor: nil,
      limit: 20
    )
    #expect(response.connections[0].uri == nil)
    #expect(!response.connections[0].editable)
    #expect(!response.recordLinksComplete)
  }

  @Test("missing collection and projection failures remain explicit")
  func upstreamErrors() async {
    let service = SembleProjectionService(
      transport: FixtureSembleTransport(responses: [
        "/network.cosmik.collection.getByAtUri": .init(statusCode: 404, body: Data())
      ]),
      recordReader: FixtureSembleRecordReader(read: .init(records: [], complete: true))
    )
    do {
      _ = try await service.collection(
        viewerDid: viewerDid,
        collectionUri: collectionUri,
        cursor: nil,
        limit: 20
      )
      Issue.record("Expected a not-found error")
    } catch let error as SembleProjectionError {
      #expect(error.status == .notFound)
      #expect(error.code == "semble_collection_not_found")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  private func collectionFixture() -> String {
    """
    {
      "id":"collection-id",
      "uri":"\(collectionUri)",
      "name":"Read Later",
      "description":"Saved research",
      "accessType":"CLOSED",
      "author":{"id":"\(viewerDid)","name":"Viewer","handle":"viewer.test"},
      "urlCards":[{
        "id":"card-id",
        "type":"URL",
        "url":"https://example.com/article",
        "uri":"\(cardUri)",
        "cardContent":{"url":"https://example.com/article","title":"Example title","description":"Example summary","publishedDate":"2026-08-20T00:00:00.000Z","siteName":"Example","imageUrl":"https://example.com/image.jpg"},
        "createdAt":"2026-08-29T00:00:00.000Z",
        "author":{"id":"\(viewerDid)","name":"Viewer","handle":"viewer.test","avatarUrl":"https://example.com/avatar.jpg"},
        "note":{"id":"note-id","text":"Worth reading"}
      }],
      "cardCount":1,
      "createdAt":"2026-08-01T00:00:00.000Z",
      "updatedAt":"2026-08-29T00:00:00.000Z",
      "pagination":{"currentPage":1,"hasMore":false}
    }
    """
  }
}

private struct FixtureSembleTransport: SembleProjectionTransport {
  let responses: [String: SembleProjectionTransportResponse]

  func get(path: String, query: [URLQueryItem]) async throws -> SembleProjectionTransportResponse {
    guard let response = responses[path] else {
      throw SembleProjectionError.upstream("Missing fixture for \(path)")
    }
    return response
  }
}

private extension SembleProjectionTransportResponse {
  static func ok(_ json: String) -> SembleProjectionTransportResponse {
    SembleProjectionTransportResponse(statusCode: 200, body: Data(json.utf8))
  }
}

private struct FixtureSembleRecordReader: SemblePublicRecordReading {
  let read: SemblePublicRecordRead

  func read(repoDid: String, collections: [String]) async throws -> SemblePublicRecordRead {
    read
  }

  static func record(
    collection: String,
    uri: String,
    cid: String?,
    json: String
  ) -> SemblePublicRecord {
    SemblePublicRecord(collection: collection, uri: uri, cid: cid, value: Data(json.utf8))
  }
}

private struct FixtureSembleRecordsByDidReader: SemblePublicRecordReading {
  let reads: [String: SemblePublicRecordRead]

  func read(repoDid: String, collections: [String]) async throws -> SemblePublicRecordRead {
    reads[repoDid] ?? .init(records: [], complete: false)
  }
}
