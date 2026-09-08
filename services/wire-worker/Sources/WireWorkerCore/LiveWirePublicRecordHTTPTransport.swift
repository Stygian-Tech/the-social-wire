import AsyncHTTPClient
import Foundation
import NIOCore

struct LiveWirePublicRecordHTTPTransport: WirePublicRecordHTTPTransport {
  let httpClient: HTTPClient

  func get(_ url: URL, maximumBytes: Int) async throws -> WirePublicRecordHTTPResponse {
    guard let host = url.host,
      url.scheme == "https", url.user == nil, url.password == nil,
      url.port == nil || url.port == 443,
      WirePublicEndpointValidator.isPublicHostname(host.lowercased())
    else { throw WirePublicRecordQueryError.unsafeEndpoint }
    let captured = WirePublicRecordAddressCapture()
    let resolver = WirePublicDNSResolver(resolver: { host in
      let addresses = WirePublicDNSResolver.resolveAddresses(host)
      captured.store(addresses)
      return addresses
    })
    try await resolver.validatePublicAddresses(for: host)
    guard let address = captured.first() else { throw WirePublicRecordQueryError.unavailable }
    // Connect to the classified address while preserving hostname TLS verification.
    var configuration = HTTPClient.Configuration()
    configuration.dnsOverride = [host: address]
    configuration.redirectConfiguration = .disallow
    let client = HTTPClient(eventLoopGroup: httpClient.eventLoopGroup, configuration: configuration)
    do {
      let response = try await withThrowingTaskGroup(of: WirePublicRecordHTTPResponse.self) { group in
        group.addTask {
          var request = HTTPClientRequest(url: url.absoluteString)
          request.headers.add(name: "Accept", value: "application/json")
          request.headers.add(name: "User-Agent", value: "TheSocialWire-DependencyHydration/1")
          let response = try await client.execute(request, timeout: .seconds(10))
          guard !(300..<400).contains(Int(response.status.code)) else {
            throw WirePublicRecordQueryError.redirected
          }
          let body: ByteBuffer
          do {
            body = try await response.body.collect(upTo: maximumBytes)
          } catch is NIOTooManyBytesError {
            throw WirePublicRecordQueryError.responseTooLarge
          }
          return WirePublicRecordHTTPResponse(status: Int(response.status.code), body: Data(buffer: body))
        }
        group.addTask {
          try await Task.sleep(for: .seconds(10))
          throw WirePublicRecordQueryError.unavailable
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
      }
      try? await client.shutdown()
      return response
    } catch {
      try? await client.shutdown()
      throw error
    }
  }
}
