import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import ThinAppViewCore

@Suite("LivePublicationSiteBaseResolver")
struct PublicationSiteBaseResolverTests {
  // `example.com` is rejected by the public-HTTPS SSRF policy, so the PDS host must be routable.
  private static let plcDocumentJSON = ##"""
    {"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.thesocialwire.social"}]}
    """##

  /// Serves the PLC directory document and the publication record from canned JSON.
  private actor StubTransport: PDSHTTPTransport {
    private let plcJSON: String
    private let recordJSON: String?
    private let recordStatus: HTTPResponseStatus
    private(set) var requestedURLs: [String] = []

    init(
      plcJSON: String = PublicationSiteBaseResolverTests.plcDocumentJSON,
      recordJSON: String?,
      recordStatus: HTTPResponseStatus = .ok
    ) {
      self.plcJSON = plcJSON
      self.recordJSON = recordJSON
      self.recordStatus = recordStatus
    }

    func execute(
      _ request: HTTPClientRequest,
      timeout: TimeAmount
    ) async throws -> HTTPClientResponse {
      requestedURLs.append(request.url)
      if request.url.contains("/xrpc/com.atproto.repo.getRecord") {
        return HTTPClientResponse(
          status: recordStatus,
          body: .bytes(ByteBuffer(string: recordJSON ?? ""))
        )
      }
      return HTTPClientResponse(status: .ok, body: .bytes(ByteBuffer(string: plcJSON)))
    }

    func getRecordRequestCount() -> Int {
      requestedURLs.filter { $0.contains("/xrpc/com.atproto.repo.getRecord") }.count
    }
  }

  private static let publication = "at://did:plc:author/site.standard.publication/main"

  @Test("resolves the site base from the publication record and caches it")
  func resolvesAndCaches() async throws {
    let transport = StubTransport(recordJSON: #"{"value":{"url":"https://example.com/"}}"#)
    let resolver = LivePublicationSiteBaseResolver(
      transport: transport,
      plcBase: "https://plc.directory"
    )

    #expect(await resolver.siteBase(forPublicationAtUri: Self.publication) == "https://example.com")
    #expect(await resolver.siteBase(forPublicationAtUri: Self.publication) == "https://example.com")
    #expect(await transport.getRecordRequestCount() == 1)
  }

  @Test("caches failures so repeated documents do not re-fetch")
  func cachesFailures() async throws {
    let transport = StubTransport(recordJSON: nil, recordStatus: .notFound)
    let resolver = LivePublicationSiteBaseResolver(
      transport: transport,
      plcBase: "https://plc.directory"
    )

    #expect(await resolver.siteBase(forPublicationAtUri: Self.publication) == nil)
    #expect(await resolver.siteBase(forPublicationAtUri: Self.publication) == nil)
    #expect(await transport.getRecordRequestCount() == 1)
  }

  @Test("returns nil when the publication record carries no HTTPS base")
  func missingSiteBase() async throws {
    let transport = StubTransport(recordJSON: #"{"value":{"title":"No Site"}}"#)
    let resolver = LivePublicationSiteBaseResolver(
      transport: transport,
      plcBase: "https://plc.directory"
    )

    #expect(await resolver.siteBase(forPublicationAtUri: Self.publication) == nil)
  }

  @Test("skips URIs that are not publication records")
  func skipsNonPublicationUris() async throws {
    let transport = StubTransport(recordJSON: #"{"value":{"url":"https://example.com"}}"#)
    let resolver = LivePublicationSiteBaseResolver(
      transport: transport,
      plcBase: "https://plc.directory"
    )

    #expect(
      await resolver.siteBase(forPublicationAtUri: "at://did:plc:author/site.standard.document/abc")
        == nil
    )
    #expect(await resolver.siteBase(forPublicationAtUri: "https://example.com") == nil)
    #expect(await transport.requestedURLs.isEmpty)
  }

  @Test("accepts the legacy com.standard publication collection")
  func acceptsLegacyCollection() async throws {
    let transport = StubTransport(recordJSON: #"{"value":{"siteUrl":"https://example.com"}}"#)
    let resolver = LivePublicationSiteBaseResolver(
      transport: transport,
      plcBase: "https://plc.directory"
    )

    #expect(
      await resolver.siteBase(
        forPublicationAtUri: "at://did:plc:author/com.standard.publication/main"
      ) == "https://example.com"
    )
  }
}
