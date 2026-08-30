import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Testing
@testable import WireWorkerCore

@Suite("The Wire talked-account profile client")
struct HTTPWireTalkedAccountProfileClientTests {
  @Test("returns only a matching public profile snapshot")
  func publicProfile() async throws {
    let client = HTTPWireTalkedAccountProfileClient(
      transport: ProfileStubTransport(body: """
        {"did":"did:plc:person","handle":"person.example","displayName":"Person",
         "avatar":"https://cdn.example/avatar.jpg","description":"Public profile","labels":[]}
        """),
      dnsResolver: ProfileStubDNSResolver()
    )
    let profile = try await client.fetch(did: "did:plc:person")
    #expect(profile.handle == "person.example")
    #expect(profile.displayName == "Person")
  }

  @Test("baseline moderation removes unsafe public profiles")
  func moderatedProfile() async {
    let client = HTTPWireTalkedAccountProfileClient(
      transport: ProfileStubTransport(body: """
        {"did":"did:plc:person","handle":"person.example","labels":[{"val":"spam"}]}
        """),
      dnsResolver: ProfileStubDNSResolver()
    )
    await #expect(throws: WireTalkedAccountProfileError.moderated) {
      try await client.fetch(did: "did:plc:person")
    }
  }
}

private struct ProfileStubDNSResolver: WireDNSResolving {
  func validatePublicAddresses(for host: String) throws {}
}

private actor ProfileStubTransport: WirePublicationHTTPTransport {
  let body: String

  init(body: String) { self.body = body }

  func execute(_ request: HTTPClientRequest, timeout: TimeAmount) throws -> HTTPClientResponse {
    var headers = HTTPHeaders()
    headers.add(name: "Content-Type", value: "application/json")
    return HTTPClientResponse(
      status: .ok,
      headers: headers,
      body: .bytes(ByteBuffer(string: body))
    )
  }
}
