import AsyncHTTPClient
import Foundation

enum WireTalkedAccountProfileError: Error, Equatable {
  case unsafeEndpoint
  case invalidResponse
  case moderated
}

struct HTTPWireTalkedAccountProfileClient: WireTalkedAccountProfileFetching {
  private struct ProfileResponse: Decodable {
    struct Label: Decodable { let val: String }
    let did: String
    let handle: String
    let displayName: String?
    let avatar: String?
    let description: String?
    let labels: [Label]?
  }

  private let transport: any WirePublicationHTTPTransport
  private let dnsResolver: any WireDNSResolving

  init(httpClient: HTTPClient) {
    self.init(
      transport: LiveWirePublicationHTTPTransport(httpClient: httpClient),
      dnsResolver: WirePublicDNSResolver()
    )
  }

  init(transport: any WirePublicationHTTPTransport, dnsResolver: any WireDNSResolving) {
    self.transport = transport
    self.dnsResolver = dnsResolver
  }

  func fetch(did: String) async throws -> WireTalkedAccountProfile {
    guard did.hasPrefix("did:"),
      var components = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile")
    else { throw WireTalkedAccountProfileError.invalidResponse }
    components.queryItems = [URLQueryItem(name: "actor", value: did)]
    guard let url = components.url, let host = url.host,
      WirePublicEndpointValidator.isPublicHostname(host)
    else { throw WireTalkedAccountProfileError.unsafeEndpoint }
    do {
      try await dnsResolver.validatePublicAddresses(for: host)
    } catch {
      throw WireTalkedAccountProfileError.unsafeEndpoint
    }

    var request = HTTPClientRequest(url: url.absoluteString)
    request.method = .GET
    request.headers.add(name: "Accept", value: "application/json")
    request.headers.add(name: "User-Agent", value: "TheSocialWire-WirePeople/1")
    let response = try await transport.execute(request, timeout: .seconds(8))
    guard response.status == .ok else {
      _ = try? await response.body.collect(upTo: 64 * 1_024)
      throw WireTalkedAccountProfileError.invalidResponse
    }
    let body = try await response.body.collect(upTo: 64 * 1_024)
    let decoded = try JSONDecoder().decode(ProfileResponse.self, from: Data(body.readableBytesView))
    guard decoded.did.lowercased() == did.lowercased(), !decoded.handle.isEmpty else {
      throw WireTalkedAccountProfileError.invalidResponse
    }
    let unsafeLabels = Set(["adult", "porn", "sexual", "graphic-media", "spam", "impersonation"])
    if decoded.labels?.contains(where: { unsafeLabels.contains($0.val.lowercased()) }) == true {
      throw WireTalkedAccountProfileError.moderated
    }
    return WireTalkedAccountProfile(
      did: decoded.did.lowercased(),
      handle: decoded.handle,
      displayName: decoded.displayName,
      avatarURL: decoded.avatar,
      description: decoded.description
    )
  }
}
