import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

struct HTTPWireLinkMetadataClient: WireLinkMetadataFetching {
  static let maximumBodyBytes = 512 * 1_024
  static let maximumRedirects = 3

  private let transport: any WirePublicationHTTPTransport
  private let dnsResolver: any WireDNSResolving

  init(httpClient: HTTPClient) {
    self.init(
      transport: LiveWirePublicationHTTPTransport(httpClient: httpClient),
      dnsResolver: WirePublicDNSResolver()
    )
  }

  init(
    transport: any WirePublicationHTTPTransport,
    dnsResolver: any WireDNSResolving
  ) {
    self.transport = transport
    self.dnsResolver = dnsResolver
  }

  func fetch(_ target: WireLinkMetadataTarget) async throws -> WireLinkMetadataFetchResult {
    guard let initialURL = URL(string: target.canonicalURL) else {
      throw WireLinkMetadataQueryError.unsafeEndpoint
    }
    var currentURL = initialURL
    for redirectCount in 0...Self.maximumRedirects {
      try await validate(currentURL)
      var request = HTTPClientRequest(url: currentURL.absoluteString)
      request.method = .GET
      request.headers.add(name: "Accept", value: "text/html,application/xhtml+xml;q=0.9")
      request.headers.add(name: "User-Agent", value: "TheSocialWire-WireMetadata/1")
      if redirectCount == 0, let etag = target.etag {
        request.headers.add(name: "If-None-Match", value: etag)
      }
      if redirectCount == 0, let lastModified = target.lastModified {
        request.headers.add(name: "If-Modified-Since", value: lastModified)
      }
      let response = try await transport.execute(request, timeout: .seconds(8))
      let responseETag = response.headers.first(name: "ETag")
      let responseLastModified = response.headers.first(name: "Last-Modified")

      if response.status == .notModified {
        await discard(response.body)
        return .notModified(etag: responseETag ?? target.etag, lastModified: responseLastModified ?? target.lastModified)
      }
      if Self.isRedirect(response.status) {
        guard redirectCount < Self.maximumRedirects,
          let location = response.headers.first(name: "Location"),
          let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL
        else {
          await discard(response.body)
          throw WireLinkMetadataQueryError.tooManyRedirects
        }
        await discard(response.body)
        currentURL = nextURL
        continue
      }
      if response.status == .tooManyRequests || response.status.code >= 500 {
        await discard(response.body)
        throw WireLinkMetadataQueryError.transientStatus(Int(response.status.code))
      }
      guard response.status == .ok else {
        await discard(response.body)
        throw WireLinkMetadataQueryError.invalidResponse
      }
      let contentType = response.headers.first(name: "Content-Type")?.lowercased() ?? ""
      guard contentType.hasPrefix("text/html") || contentType.hasPrefix("application/xhtml+xml") else {
        await discard(response.body)
        throw WireLinkMetadataQueryError.unsupportedContentType
      }
      let body: ByteBuffer
      do {
        body = try await response.body.collect(upTo: Self.maximumBodyBytes)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw WireLinkMetadataQueryError.responseTooLarge
      }
      let html = String(decoding: body.readableBytesView, as: UTF8.self)
      guard let parsed = WireOpenGraphParser.parse(html: html, pageURL: currentURL) else {
        throw WireLinkMetadataQueryError.invalidResponse
      }
      return .metadata(
        WireLinkMetadata(
          canonicalURL: parsed.canonicalURL,
          title: parsed.title,
          description: parsed.description,
          imageURL: parsed.imageURL,
          siteName: parsed.siteName,
          iconURL: parsed.iconURL,
          etag: responseETag,
          lastModified: responseLastModified,
          source: .openGraph
        )
      )
    }
    throw WireLinkMetadataQueryError.tooManyRedirects
  }

  private func validate(_ url: URL) async throws {
    guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
      url.user == nil, url.password == nil, WirePublicEndpointValidator.isPublicHostname(host)
    else { throw WireLinkMetadataQueryError.unsafeEndpoint }
    do {
      try await dnsResolver.validatePublicAddresses(for: host)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw WireLinkMetadataQueryError.unsafeEndpoint
    }
  }

  private func discard(_ body: HTTPClientResponse.Body) async {
    _ = try? await body.collect(upTo: 16 * 1_024)
  }

  private static func isRedirect(_ status: HTTPResponseStatus) -> Bool {
    [301, 302, 303, 307, 308].contains(Int(status.code))
  }
}
