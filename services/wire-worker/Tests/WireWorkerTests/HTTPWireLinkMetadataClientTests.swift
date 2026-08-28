import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Testing
@testable import WireWorker

@Suite("The Wire OpenGraph HTTP client")
struct HTTPWireLinkMetadataClientTests {
  @Test("uses validators and accepts a bounded HTML response")
  func conditionalFetch() async throws {
    var headers = HTTPHeaders()
    headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
    headers.add(name: "ETag", value: "\"edition-one\"")
    let transport = StubWireLinkTransport(responses: [
      .init(
        status: .ok,
        headers: headers,
        body: #"<html lang="fr-CA"><meta property="og:title" content="Story"></html>"#
      )
    ])
    let dns = StubWireLinkDNSResolver()
    let client = HTTPWireLinkMetadataClient(transport: transport, dnsResolver: dns)
    let result = try await client.fetch(
      WireLinkMetadataTarget(
        canonicalKey: "url:one",
        canonicalURL: "https://publisher.social/story",
        etag: "\"old\"",
        lastModified: "Wed, 20 Aug 2026 12:00:00 GMT"
      )
    )
    guard case .metadata(let metadata) = result else {
      Issue.record("Expected metadata")
      return
    }
    #expect(metadata.title == "Story")
    #expect(metadata.languageCode == "fr")
    #expect(metadata.etag == "\"edition-one\"")
    #expect(await dns.hosts == ["publisher.social"])
    let requests = await transport.requests
    #expect(requests.first?.headers.first(name: "If-None-Match") == "\"old\"")
  }

  @Test("preserves validators on a 304 refresh")
  func notModified() async throws {
    var headers = HTTPHeaders()
    headers.add(name: "ETag", value: "\"edition-two\"")
    let client = HTTPWireLinkMetadataClient(
      transport: StubWireLinkTransport(responses: [
        .init(status: .notModified, headers: headers, body: "")
      ]),
      dnsResolver: StubWireLinkDNSResolver()
    )
    let result = try await client.fetch(
      WireLinkMetadataTarget(
        canonicalKey: "url:one",
        canonicalURL: "https://publisher.social/story",
        etag: "\"edition-one\"",
        lastModified: "Wed, 20 Aug 2026 12:00:00 GMT"
      )
    )
    #expect(result == .notModified(
      etag: "\"edition-two\"",
      lastModified: "Wed, 20 Aug 2026 12:00:00 GMT"
    ))
  }

  @Test("rejects non-HTML responses")
  func rejectsNonHTML() async {
    var headers = HTTPHeaders()
    headers.add(name: "Content-Type", value: "application/json")
    let client = HTTPWireLinkMetadataClient(
      transport: StubWireLinkTransport(responses: [
        .init(status: .ok, headers: headers, body: "{}")
      ]),
      dnsResolver: StubWireLinkDNSResolver()
    )
    await #expect(throws: WireLinkMetadataQueryError.unsupportedContentType) {
      try await client.fetch(
        WireLinkMetadataTarget(
          canonicalKey: "url:one", canonicalURL: "https://publisher.social/story",
          etag: nil, lastModified: nil)
      )
    }
  }

  @Test("revalidates every redirect and rejects a private destination")
  func redirectValidation() async throws {
    var headers = HTTPHeaders()
    headers.add(name: "Location", value: "https://private.publisher.social/story")
    let transport = StubWireLinkTransport(responses: [
      .init(status: .found, headers: headers, body: "")
    ])
    let dns = StubWireLinkDNSResolver(blockedHost: "private.publisher.social")
    let client = HTTPWireLinkMetadataClient(transport: transport, dnsResolver: dns)
    await #expect(throws: WireLinkMetadataQueryError.unsafeEndpoint) {
      try await client.fetch(
        WireLinkMetadataTarget(
          canonicalKey: "url:one", canonicalURL: "https://publisher.social/story",
          etag: nil, lastModified: nil)
      )
    }
    #expect(await dns.hosts == ["publisher.social", "private.publisher.social"])
  }
}

private actor StubWireLinkDNSResolver: WireDNSResolving {
  let blockedHost: String?
  private(set) var hosts: [String] = []

  init(blockedHost: String? = nil) { self.blockedHost = blockedHost }

  func validatePublicAddresses(for host: String) throws {
    hosts.append(host)
    if host == blockedHost { throw WirePublicationQueryError.unsafeEndpoint }
  }
}

private actor StubWireLinkTransport: WirePublicationHTTPTransport {
  struct Response: Sendable {
    let status: HTTPResponseStatus
    let headers: HTTPHeaders
    let body: String
  }

  private var responses: [Response]
  private(set) var requests: [HTTPClientRequest] = []

  init(responses: [Response]) { self.responses = responses }

  func execute(_ request: HTTPClientRequest, timeout: TimeAmount) throws -> HTTPClientResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw WireLinkMetadataQueryError.invalidResponse }
    let response = responses.removeFirst()
    return HTTPClientResponse(
      status: response.status,
      headers: response.headers,
      body: .bytes(ByteBuffer(string: response.body))
    )
  }
}
