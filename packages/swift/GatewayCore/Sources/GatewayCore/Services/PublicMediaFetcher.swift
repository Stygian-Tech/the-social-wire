import AsyncHTTPClient
import Foundation
import NIOCore

/// Bounded public source fetch with address pinning and validation on every redirect.
public enum PublicMediaFetcher {
  public static func stream(url: String, httpClient: HTTPClient, range: String?) async throws -> (
    response: HTTPClientResponse, client: HTTPClient
  ) {
    var current = url
    for _ in 0..<6 {
      guard let components = URLComponents(string: current), let host = components.host,
        components.scheme == "https", components.user == nil, components.password == nil
      else { throw PDSAccessTokenAttestationError.invalid }
      let address = try await PublicDNSAddressValidator.validatedAddress(for: current)
      var config = HTTPClient.Configuration()
      config.timeout = .init(connect: .seconds(10), read: .seconds(60))
      config.dnsOverride = [host: address]
      config.redirectConfiguration = .disallow
      let client = HTTPClient(eventLoopGroup: httpClient.eventLoopGroup, configuration: config)
      do {
        var request = HTTPClientRequest(url: current)
        if let range { request.headers.add(name: "Range", value: range) }
        let response = try await client.execute(request, timeout: .hours(6))
        if [301, 302, 303, 307, 308].contains(response.status.code),
          let location = response.headers.first(name: "location"),
          let next = URL(string: location, relativeTo: URL(string: current))?.absoluteURL
            .absoluteString
        {
          try await client.shutdown()
          current = next
          continue
        }
        return (response, client)
      } catch {
        try? await client.shutdown()
        throw error
      }
    }
    throw PDSAccessTokenAttestationError.unavailable
  }
  public static func fingerprint(url: String, httpClient: HTTPClient) async throws -> String? {
    var current = url
    for _ in 0..<6 {
      guard let components = URLComponents(string: current), let host = components.host,
        components.scheme == "https", components.user == nil, components.password == nil
      else { throw PDSAccessTokenAttestationError.invalid }
      let address = try await PublicDNSAddressValidator.validatedAddress(for: current)
      var configuration = HTTPClient.Configuration()
      configuration.dnsOverride = [host: address]
      configuration.redirectConfiguration = .disallow
      let client = HTTPClient(
        eventLoopGroup: httpClient.eventLoopGroup, configuration: configuration)
      do {
        var request = HTTPClientRequest(url: current)
        request.method = .HEAD
        let response = try await client.execute(request, timeout: .seconds(10))
        if [301, 302, 303, 307, 308].contains(response.status.code),
          let location = response.headers.first(name: "location"),
          let next = URL(string: location, relativeTo: URL(string: current))?.absoluteURL
            .absoluteString
        {
          try await client.shutdown()
          current = next
          continue
        }
        let etag = response.headers.first(name: "ETag")
        let modified = response.headers.first(name: "Last-Modified")
        let length = response.headers.first(name: "Content-Length")
        try await client.shutdown()
        guard response.status.code == 200, etag != nil || modified != nil else { return nil }
        return [url, etag ?? "", modified ?? "", length ?? ""].joined(separator: "|")
      } catch {
        try? await client.shutdown()
        throw error
      }
    }
    return nil
  }
  public static func fetch(
    url: String, httpClient: HTTPClient, maximumBytes: Int,
    validateURL: (@Sendable (String) -> Bool)? = nil, timeout: Duration = .seconds(25),
    requestHeaders: [(String, String)] = [], requiredContentType: String? = nil
  ) async throws
    -> Data
  {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var current = url
    for _ in 0..<6 {
      guard ContinuousClock.now < deadline else { throw PDSAccessTokenAttestationError.unavailable }
      if let validateURL, !validateURL(current) { throw PDSAccessTokenAttestationError.invalid }
      guard let components = URLComponents(string: current), let host = components.host,
        components.scheme == "https", components.user == nil, components.password == nil
      else { throw PDSAccessTokenAttestationError.invalid }
      let address = try await PublicDNSAddressValidator.validatedAddress(for: current, deadline: deadline)
      var configuration = HTTPClient.Configuration()
      configuration.dnsOverride = [host: address]
      configuration.redirectConfiguration = .disallow
      let client = HTTPClient(
        eventLoopGroup: httpClient.eventLoopGroup, configuration: configuration)
      do {
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let nanos = remaining.seconds * 1_000_000_000 + remaining.attoseconds / 1_000_000_000
        guard nanos > 0 else { throw PDSAccessTokenAttestationError.unavailable }
        var request = HTTPClientRequest(url: current)
        for (name, value) in requestHeaders { request.headers.add(name: name, value: value) }
        let response = try await client.execute(request, timeout: .nanoseconds(nanos))
        if [301, 302, 303, 307, 308].contains(response.status.code),
          let location = response.headers.first(name: "location"),
          let next = URL(string: location, relativeTo: URL(string: current))?.absoluteURL
            .absoluteString
        {
          try await client.shutdown()
          current = next
          continue
        }
        guard response.status.code == 200 else { throw PDSAccessTokenAttestationError.unavailable }
        let body = try await collectBeforeDeadline(response, maximumBytes: maximumBytes, deadline: deadline, requiredContentType: requiredContentType)
        try await client.shutdown()
        return body
      } catch {
        try? await client.shutdown()
        throw error
      }
    }
    throw PDSAccessTokenAttestationError.unavailable
  }
  /// AHC's execute timeout ends at response headers; bound body consumption separately.
  static func collectBeforeDeadline(_ response: HTTPClientResponse, maximumBytes: Int,
    deadline: ContinuousClock.Instant, requiredContentType: String? = nil) async throws -> Data {
    if let requiredContentType {
      guard response.headers.first(name: "Content-Type")?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == requiredContentType.lowercased()
      else { throw PDSAccessTokenAttestationError.unavailable }
    }
    return try await withThrowingTaskGroup(of: Data.self) { group in
      defer { group.cancelAll() }
      group.addTask { Data(buffer: try await response.body.collect(upTo: maximumBytes)) }
      group.addTask {
        try await Task.sleep(until: deadline, clock: .continuous)
        throw PDSAccessTokenAttestationError.unavailable
      }
      guard let data = try await group.next(), ContinuousClock.now < deadline else {
        throw PDSAccessTokenAttestationError.unavailable
      }
      return data
    }
  }

}
