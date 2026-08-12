import AsyncHTTPClient
import Foundation
import SocialWireRedis

enum ThinAppViewPdsResolution {
  static func resolvePdsBase(
    repoDid: String,
    plcBase: String,
    httpClient: HTTPClient,
    cache: (any PDSResolutionCache)? = nil
  ) async throws -> String? {
    try await resolvePdsBase(
      repoDid: repoDid,
      plcBase: plcBase,
      transport: LivePDSHTTPTransport(httpClient: httpClient),
      endpointPolicy: .publicHTTPS,
      cache: cache
    )
  }

  static func resolvePdsBase(
    repoDid: String,
    plcBase: String,
    transport: any PDSHTTPTransport,
    endpointPolicy: PDSResolvedEndpointPolicy,
    cache explicitCache: (any PDSResolutionCache)? = nil
  ) async throws -> String? {
    try Task.checkCancellation()
    guard repoDid.hasPrefix("did:") else { return nil }
    let cache = if let explicitCache {
      explicitCache
    } else {
      await PDSResolutionCacheRegistry.shared.current()
    }
    var heldLease: RedisLease?
    do {
      switch try await cache.lookup(did: repoDid) {
      case .fresh(let endpoint):
        return try validatedCachedEndpoint(endpoint, policy: endpointPolicy)
      case .stale(let endpoint):
        guard let lease = try await cache.acquireLease(did: repoDid, ttl: 15) else {
          return try validatedCachedEndpoint(endpoint, policy: endpointPolicy)
        }
        heldLease = lease
      case .miss:
        if let lease = try await cache.acquireLease(did: repoDid, ttl: 15) {
          heldLease = lease
        } else if let contender = try await waitForContender(cache: cache, did: repoDid) {
          return try validatedCachedEndpoint(contender, policy: endpointPolicy)
        }
      }
    } catch let error as ThinAppViewPdsResolutionError {
      throw error
    } catch {
      // Redis is fail-open; continue with the authoritative PLC request.
    }
    defer {
      if let heldLease {
        Task { await cache.releaseLease(heldLease) }
      }
    }

    let encoded = repoDid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoDid
    var root = plcBase.trimmingCharacters(in: .whitespacesAndNewlines)
    while root.hasSuffix("/") { root.removeLast() }

    var request = HTTPClientRequest(url: "\(root)/\(encoded)")
    request.headers.add(name: "Accept", value: "application/json")
    let response = try await transport.execute(request, timeout: .seconds(15))
    if response.status == .tooManyRequests || response.status.code >= 500 {
      try await HTTPResponseBodyDrain.drainOrCancel(response.body)
      throw ThinAppViewPdsResolutionError.transientStatus(response.status.code)
    }
    guard response.status == .ok else {
      try await HTTPResponseBodyDrain.drainOrCancel(response.body)
      try? await cache.storeUnresolved(did: repoDid, now: Date())
      return nil
    }

    let body = try await response.body.collect(upTo: 64 * 1024)
    try Task.checkCancellation()
    guard
      let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
      let services = json["service"] as? [[String: Any]]
    else { return nil }

    for service in services {
      let id = service["id"] as? String
      let type = service["type"] as? String
      guard let endpoint = service["serviceEndpoint"] as? String else { continue }
      if id == "#atproto_pds" || type == "AtprotoPersonalDataServer" {
        guard
          let base = PDSResolvedEndpointValidator.validatedBase(
            endpoint,
            policy: endpointPolicy
          )
        else { throw ThinAppViewPdsResolutionError.unsafeServiceEndpoint }
        try? await cache.storeResolved(did: repoDid, endpoint: base, now: Date())
        return base
      }
    }
    try? await cache.storeUnresolved(did: repoDid, now: Date())
    return nil
  }

  private static func waitForContender(
    cache: any PDSResolutionCache,
    did: String
  ) async throws -> String?? {
    for _ in 0..<5 {
      try await Task.sleep(for: .milliseconds(50))
      switch try await cache.lookup(did: did) {
      case .fresh(let endpoint), .stale(let endpoint): return .some(endpoint)
      case .miss: continue
      }
    }
    return nil
  }

  private static func validatedCachedEndpoint(
    _ endpoint: String?,
    policy: PDSResolvedEndpointPolicy
  ) throws -> String? {
    guard let endpoint else { return nil }
    guard let validated = PDSResolvedEndpointValidator.validatedBase(endpoint, policy: policy) else {
      throw ThinAppViewPdsResolutionError.unsafeServiceEndpoint
    }
    return validated
  }
}

enum ThinAppViewPdsResolutionError: Error, Equatable {
  case unsafeServiceEndpoint
  case transientStatus(UInt)
}
