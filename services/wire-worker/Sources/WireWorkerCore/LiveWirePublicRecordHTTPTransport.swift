import AsyncHTTPClient
import Foundation
import NIOCore
import NIOPosix

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
    guard let addresses = captured.addresses() else { throw WirePublicRecordQueryError.unavailable }
    return try await WirePublicRecordAddressFallback.run(addresses: addresses) { address in
      try await request(url, host: host, address: address, maximumBytes: maximumBytes)
    }
  }

  private func request(_ url: URL, host: String, address: String, maximumBytes: Int) async throws -> WirePublicRecordHTTPResponse {
    // Connect to the classified address while preserving hostname TLS verification.
    var configuration = HTTPClient.Configuration()
    configuration.dnsOverride = [host: address]
    configuration.redirectConfiguration = .disallow
    configuration.timeout.connect = .seconds(3)
    let client = HTTPClient(eventLoopGroup: httpClient.eventLoopGroup, configuration: configuration)
    var receivedResponse = false
    do {
      var request = HTTPClientRequest(url: url.absoluteString)
      request.headers.add(name: "Accept", value: "application/json")
      request.headers.add(name: "User-Agent", value: "TheSocialWire-DependencyHydration/1")
      let response = try await client.execute(request, timeout: .seconds(10))
      receivedResponse = true
      guard !(300..<400).contains(Int(response.status.code)) else {
        throw WirePublicRecordQueryError.redirected
      }
      let body: ByteBuffer
      do { body = try await response.body.collect(upTo: maximumBytes) }
      catch is NIOTooManyBytesError { throw WirePublicRecordQueryError.responseTooLarge }
      try? await client.shutdown()
      return WirePublicRecordHTTPResponse(status: Int(response.status.code), body: Data(buffer: body))
    } catch {
      try? await client.shutdown()
      try Task.checkCancellation()
      // Once a server responds, HTTP/protocol/body semantics must never cause an
      // address retry. TLS validation errors likewise propagate without fallback.
      if Self.isConnectionFailure(error, receivedResponse: receivedResponse) {
        throw WirePublicRecordAddressFallback.Failure.connection
      }
      throw error
    }
  }

  static func isConnectionFailure(_ error: any Error, receivedResponse: Bool = false) -> Bool {
    guard !receivedResponse else { return false }
    if error is IOError { return true }
    if let failures = error as? NIOConnectionError {
      return !failures.connectionErrors.isEmpty
        && failures.connectionErrors.allSatisfy { isConnectionFailure($0.error) }
    }
    if let error = error as? HTTPClientError {
      return [HTTPClientError.connectTimeout, .readTimeout, .writeTimeout,
        .remoteConnectionClosed, .deadlineExceeded].contains(error)
    }
    if let error = error as? ChannelError {
      switch error {
      case .connectTimeout, .ioOnClosedChannel, .alreadyClosed: return true
      default: return false
      }
    }
    return false
  }
}
