import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import WireWorker

@Suite("Wire publication PDS query client")
struct HTTPWirePublicationQueryClientTests {
  @Test("resolves a PLC DID and performs one bounded getRecord request")
  func plcResolution() async throws {
    let transport = StubWirePublicationHTTPTransport(responses: [
      .init(
        status: .ok,
        json:
          ##"{"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.publisher.social"}]}"##
      ),
      .init(
        status: .ok,
        json:
          #"{"value":{"$type":"site.standard.publication","name":"Publisher","url":"https://publisher.social/"}}"#
      ),
    ])
    let client = HTTPWirePublicationQueryClient(
      transport: transport,
      dnsResolver: StubWireDNSResolver(),
      plcDirectoryBase: URL(string: "https://plc.directory")!
    )
    let reference = try #require(
      WirePublicationReference.parse("at://did:plc:author/site.standard.publication/main")
    )
    let metadata = try await client.query(publication: reference)
    #expect(metadata?.siteURL == "https://publisher.social")
    #expect(metadata?.name == "Publisher")
    let urls = await transport.requestedURLs
    #expect(urls.count == 2)
    #expect(urls[0].hasPrefix("https://plc.directory/did:plc:author"))
    #expect(urls[1].hasPrefix("https://pds.publisher.social/xrpc/com.atproto.repo.getRecord?"))
    #expect(urls[1].contains("collection=site.standard.publication"))
  }

  @Test("rejects a private or loopback PDS endpoint")
  func rejectsUnsafeEndpoint() async throws {
    let transport = StubWirePublicationHTTPTransport(responses: [
      .init(
        status: .ok,
        json: ##"{"service":[{"id":"#atproto_pds","serviceEndpoint":"http://127.0.0.1:3000"}]}"##
      )
    ])
    let client = HTTPWirePublicationQueryClient(
      transport: transport,
      dnsResolver: StubWireDNSResolver(),
      plcDirectoryBase: URL(string: "https://plc.directory")!
    )
    let reference = try #require(
      WirePublicationReference.parse("at://did:plc:author/site.standard.publication/main")
    )
    await #expect(throws: WirePublicationQueryError.unsafeEndpoint) {
      try await client.query(publication: reference)
    }
    #expect(await transport.requestedURLs.count == 1)
  }

  @Test("treats rate limits as retryable query errors")
  func rateLimit() async throws {
    let transport = StubWirePublicationHTTPTransport(responses: [
      .init(status: .tooManyRequests, json: #"{"error":"RateLimitExceeded"}"#)
    ])
    let client = HTTPWirePublicationQueryClient(
      transport: transport,
      dnsResolver: StubWireDNSResolver(),
      plcDirectoryBase: URL(string: "https://plc.directory")!
    )
    let reference = try #require(
      WirePublicationReference.parse("at://did:plc:author/site.standard.publication/main")
    )
    await #expect(throws: WirePublicationQueryError.transientStatus(429)) {
      try await client.query(publication: reference)
    }
  }

  @Test("rejects decoded traversal in a did:web identifier before network access")
  func rejectsDIDWebTraversal() async throws {
    let transport = StubWirePublicationHTTPTransport(responses: [])
    let client = HTTPWirePublicationQueryClient(
      transport: transport,
      dnsResolver: StubWireDNSResolver(),
      plcDirectoryBase: URL(string: "https://plc.directory")!
    )
    let reference = try #require(
      WirePublicationReference.parse(
        "at://did:web:publisher.social:%2e%2e/site.standard.publication/main"
      )
    )
    await #expect(throws: WirePublicationQueryError.invalidDID) {
      try await client.query(publication: reference)
    }
    #expect(await transport.requestedURLs.isEmpty)
  }

  @Test("revalidates PLC and PDS DNS immediately before each HTTP request")
  func validatesEveryRequestDNS() async throws {
    let transport = StubWirePublicationHTTPTransport(responses: [
      .init(
        status: .ok,
        json:
          ##"{"service":[{"id":"#atproto_pds","serviceEndpoint":"https://pds.publisher.social"}]}"##
      )
    ])
    let dns = StubWireDNSResolver(blockedHost: "pds.publisher.social")
    let client = HTTPWirePublicationQueryClient(
      transport: transport,
      dnsResolver: dns,
      plcDirectoryBase: URL(string: "https://plc.directory")!
    )
    let reference = try #require(
      WirePublicationReference.parse("at://did:plc:author/site.standard.publication/main")
    )
    await #expect(throws: WirePublicationQueryError.unsafeEndpoint) {
      try await client.query(publication: reference)
    }
    #expect(await dns.validatedHosts == ["plc.directory", "pds.publisher.social"])
    #expect(await transport.requestedURLs.count == 1)
  }
}

private actor StubWireDNSResolver: WireDNSResolving {
  let blockedHost: String?
  private(set) var validatedHosts: [String] = []

  init(blockedHost: String? = nil) { self.blockedHost = blockedHost }

  func validatePublicAddresses(for host: String) async throws {
    validatedHosts.append(host)
    if host == blockedHost { throw WirePublicationQueryError.unsafeEndpoint }
  }
}

private actor StubWirePublicationHTTPTransport: WirePublicationHTTPTransport {
  struct Response: Sendable {
    let status: HTTPResponseStatus
    let json: String
  }

  private var responses: [Response]
  private(set) var requestedURLs: [String] = []

  init(responses: [Response]) { self.responses = responses }

  func execute(_ request: HTTPClientRequest, timeout: TimeAmount) throws -> HTTPClientResponse {
    requestedURLs.append(request.url)
    guard !responses.isEmpty else { throw WirePublicationQueryError.invalidResponse }
    let response = responses.removeFirst()
    return HTTPClientResponse(
      status: response.status,
      body: .bytes(ByteBuffer(string: response.json))
    )
  }
}
