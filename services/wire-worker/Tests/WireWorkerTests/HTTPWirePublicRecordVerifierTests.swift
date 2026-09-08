import Foundation
import Testing

@testable import WireWorkerCore

@Suite("Bounded public record verification")
struct HTTPWirePublicRecordVerifierTests {
  private let did = "did:plc:5amsebbtpuqieuxuqadmmvcv"
  private let cid = "bafyreia2xyaul6u7nan4ee5zt2yig447staw3cvsklmf6bocfyerld7epi"
  private let revision = "3mugft5mcae2x"
  private var uri: String { "at://\(did)/site.standard.document/record" }

  @Test("verifies an exact record between stable revisions without repository enumeration")
  func stableRecord() async throws {
    let transport = PublicRecordStub(responses: responses())
    let timestamp = Date(timeIntervalSince1970: 100)
    let client = HTTPWirePublicRecordVerifier(transport: transport, now: { timestamp })
    guard case .verified(let result) = try await client.verify(uri: uri, expectedCID: nil) else {
      Issue.record("Expected a verified record"); return
    }
    #expect(result.uri == uri)
    #expect(result.cid == cid)
    #expect(result.repositoryRevision == revision)
    #expect(result.observedAt == timestamp)
    #expect(result.pdsBase == "https://pds.publisher.social")
    #expect(try JSONSerialization.jsonObject(with: result.recordJSON) as? [String: String] == ["$type": "site.standard.document", "title": "Article"])
    let requests = await transport.requests
    #expect(requests.map { $0.url.lastPathComponent } == [did, "com.atproto.sync.getRepoStatus", "com.atproto.sync.getLatestCommit", "com.atproto.repo.getRecord", "com.atproto.sync.getLatestCommit", "com.atproto.sync.getRepoStatus"])
    #expect(requests.allSatisfy { $0.url.scheme == "https" && $0.url.user == nil && $0.url.password == nil })
    #expect(requests.map(\.maximumBytes) == [65536, 65536, 65536, 1048576, 65536, 65536])
  }

  @Test("changed retained CID remains distinct from missing")
  func changedRecord() async throws {
    let other = "bafyreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    #expect(WirePublicRecordReference.validCID(other))
    let client = HTTPWirePublicRecordVerifier(transport: PublicRecordStub(responses: responses()))
    guard case .changed(let current, let observation) = try await client.verify(uri: uri, expectedCID: other) else {
      Issue.record("Expected changed CID"); return
    }
    #expect(current == cid)
    #expect(observation.repositoryRevision == revision)
    #expect(observation.expectedCID == other)
  }

  @Test("RecordNotFound is explicit only after stable active repository verification")
  func missingRecord() async throws {
    var values = responses()
    values[3] = .init(status: 400, object: ["error": "RecordNotFound"])
    let transport = PublicRecordStub(responses: values)
    let client = HTTPWirePublicRecordVerifier(transport: transport)
    guard case .missing(let observation) = try await client.verify(uri: uri, expectedCID: nil) else {
      Issue.record("Expected missing record"); return
    }
    #expect(await transport.requests.count == 6)
    #expect(observation.repositoryRevision == revision)
  }

  @Test("a repository revision change retries rather than sealing a mixed snapshot")
  func changedRepository() async throws {
    var values = responses()
    values[4] = .init(object: ["cid": cid, "rev": "3mugft5mcae2y"])
    let client = HTTPWirePublicRecordVerifier(transport: PublicRecordStub(responses: values))
    await #expect(throws: WirePublicRecordQueryError.repositoryChanged) {
      try await client.verify(uri: uri, expectedCID: nil)
    }
  }

  @Test("the same revision with a different commit CID cannot seal a snapshot")
  func changedCommitCID() async throws {
    var values = responses()
    values[4] = .init(object: [
      "cid": "bafyreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "rev": revision,
    ])
    let transport = PublicRecordStub(responses: values)
    let client = HTTPWirePublicRecordVerifier(transport: transport)
    await #expect(throws: WirePublicRecordQueryError.repositoryChanged) {
      try await client.verify(uri: uri, expectedCID: nil)
    }
    #expect(await transport.requests.count == 5)
  }

  @Test("inactive repository before or after the read cannot hydrate", arguments: [1, 5])
  func inactiveRepository(index: Int) async throws {
    var values = responses()
    values[index] = .init(object: ["did": did, "active": false])
    let transport = PublicRecordStub(responses: values)
    guard case .inactive = try await HTTPWirePublicRecordVerifier(transport: transport).verify(uri: uri, expectedCID: nil) else {
      Issue.record("Expected inactive repository"); return
    }
    #expect(await transport.requests.count == index + 1)
  }

  @Test("URI, collection type and CID mismatches fail closed", arguments: ["uri", "type", "cid", "did", "commit"])
  func invalidEnvelope(field: String) async throws {
    var values = responses()
    switch field {
    case "uri": values[3] = .init(object: ["uri": uri + "wrong", "cid": cid, "value": ["$type": "site.standard.document"]])
    case "type": values[3] = .init(object: ["uri": uri, "cid": cid, "value": ["$type": "site.standard.graph.recommend"]])
    case "cid": values[3] = .init(object: ["uri": uri, "cid": "invented", "value": ["$type": "site.standard.document"]])
    case "did": values[0] = .init(object: ["id": "did:plc:wrong", "service": []])
    default: values[2] = .init(object: ["cid": cid, "rev": "not-a-revision"])
    }
    await #expect(throws: WirePublicRecordQueryError.invalidResponse) {
      try await HTTPWirePublicRecordVerifier(transport: PublicRecordStub(responses: values)).verify(uri: uri, expectedCID: nil)
    }
  }

  @Test("transient HTTP responses remain retryable", arguments: [429, 500, 503])
  func transientStatus(status: Int) async throws {
    let client = HTTPWirePublicRecordVerifier(transport: PublicRecordStub(responses: [.init(status: status, object: ["error": "Unavailable"])]))
    await #expect(throws: WirePublicRecordQueryError.transientStatus(status)) {
      try await client.verify(uri: uri, expectedCID: nil)
    }
  }

  @Test("transport diagnostics become a bounded retryable error")
  func transportError() async throws {
    let client = HTTPWirePublicRecordVerifier(transport: PublicRecordFailingTransport())
    await #expect(throws: WirePublicRecordQueryError.unavailable) {
      try await client.verify(uri: uri, expectedCID: nil)
    }
  }

  @Test("PDS redirects are rejected")
  func redirect() async throws {
    let client = HTTPWirePublicRecordVerifier(transport: PublicRecordStub(responses: [.init(status: 302, object: [:])]))
    await #expect(throws: WirePublicRecordQueryError.redirected) { try await client.verify(uri: uri, expectedCID: nil) }
  }

  @Test("private, credentialed and nonstandard-port PDS endpoints are rejected", arguments: ["http://pds.publisher.social", "https://127.0.0.1", "https://db.railway.internal", "https://user:secret@pds.publisher.social", "https://pds.publisher.social:8443"])
  func unsafeEndpoint(endpoint: String) async throws {
    let transport = PublicRecordStub(responses: [.init(object: ["id": did, "service": [["id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": endpoint]]])])
    await #expect(throws: WirePublicRecordQueryError.unsafeEndpoint) {
      try await HTTPWirePublicRecordVerifier(transport: transport).verify(uri: uri, expectedCID: nil)
    }
    #expect(await transport.requests.count == 1)
  }

  @Test("missing retained CID is rejected for recommendations before network access")
  func recommendationRequiresCID() async throws {
    let transport = PublicRecordStub(responses: [])
    await #expect(throws: WirePublicRecordQueryError.invalidReference) {
      try await HTTPWirePublicRecordVerifier(transport: transport).verify(uri: "at://\(did)/site.standard.graph.recommend/record", expectedCID: nil)
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test("did:web paths are decoded safely")
  func webDID() throws {
    let reference = try WirePublicRecordReference("at://did:web:publisher.social:authors:alice/site.standard.document/record")
    #expect(try reference.didDocumentURL().absoluteString == "https://publisher.social/authors/alice/did.json")
    #expect(throws: WirePublicRecordQueryError.invalidReference) {
      try WirePublicRecordReference("at://did:web:publisher.social:%2e%2e/site.standard.document/record")
    }
  }

  @Test("oversized bodies fail closed")
  func oversizedBody() async throws {
    let transport = PublicRecordStub(responses: [.init(status: 200, body: Data(repeating: 32, count: 65537))])
    await #expect(throws: WirePublicRecordQueryError.responseTooLarge) {
      try await HTTPWirePublicRecordVerifier(transport: transport).verify(uri: uri, expectedCID: nil)
    }
  }

  private func responses() -> [WirePublicRecordHTTPResponse] {
    [
      .init(object: ["id": did, "service": [["id": did + "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": "https://pds.publisher.social"]]]),
      .init(object: ["did": did, "active": true]),
      .init(object: ["cid": cid, "rev": revision]),
      .init(object: ["uri": uri, "cid": cid, "value": ["$type": "site.standard.document", "title": "Article"]]),
      .init(object: ["cid": cid, "rev": revision]),
      .init(object: ["did": did, "active": true]),
    ]
  }
}

private actor PublicRecordStub: WirePublicRecordHTTPTransport {
  struct Request: Sendable { let url: URL; let maximumBytes: Int }
  private var responses: [WirePublicRecordHTTPResponse]
  private(set) var requests: [Request] = []

  init(responses: [WirePublicRecordHTTPResponse]) { self.responses = responses }

  func get(_ url: URL, maximumBytes: Int) async throws -> WirePublicRecordHTTPResponse {
    requests.append(Request(url: url, maximumBytes: maximumBytes))
    guard !responses.isEmpty else { throw WirePublicRecordQueryError.unavailable }
    return responses.removeFirst()
  }
}

private extension WirePublicRecordHTTPResponse {
  init(status: Int = 200, object: [String: Any]) {
    self.init(status: status, body: try! JSONSerialization.data(withJSONObject: object))
  }
}

private struct PublicRecordFailingTransport: WirePublicRecordHTTPTransport {
  func get(_ url: URL, maximumBytes: Int) async throws -> WirePublicRecordHTTPResponse {
    throw NSError(domain: "untrusted-transport-detail", code: 1)
  }
}
