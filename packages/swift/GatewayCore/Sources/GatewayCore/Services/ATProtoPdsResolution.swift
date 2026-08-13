import AsyncHTTPClient
import Foundation
import NIOCore
import SocialWireRedis

/// Raised when PLC could not be consulted, as distinct from PLC answering "this DID has no PDS".
public struct ATProtoPdsResolutionUnavailable: Error, Sendable {
  public let status: UInt

  public init(status: UInt) {
    self.status = status
  }
}

/// PLC → `#atproto_pds` resolution and small ATProto HTTP quirks shared by repo readers.
/// Mirrors `apps/web/src/lib/atprotoClient.ts` behavior for PDS base URL and Bridgy `listRecords` params.
public enum ATProtoPdsResolution: Sendable {
  /// Public App View — identity, graph, profile. Do not use for `com.atproto.repo.*` on third-party repos.
  public static let bskyAppViewPublic = "https://public.api.bsky.app"

  /// Some PLC `#atproto_pds` endpoints (notably Bridgy Fed relay) reject `reverse=true` on `listRecords`.
  public static func relayHostOmitsListRecordsReverse(pdsBase: String) -> Bool {
    guard let host = URL(string: pdsBase)?.host?.lowercased() else { return false }
    return host == "atproto.brid.gy" || host.hasSuffix(".brid.gy")
  }

  public static func normalizePdsBase(_ endpoint: String) -> String {
    var s = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("/") { s.removeLast() }
    return s
  }

  public static func parsePdsEndpointFromPlcDoc(_ json: [String: Any]) -> String? {
    guard let services = json["service"] as? [[String: Any]] else { return nil }
    for s in services {
      let id = s["id"] as? String
      let type = s["type"] as? String
      guard let ep = s["serviceEndpoint"] as? String else { continue }
      if id == "#atproto_pds" || type == "AtprotoPersonalDataServer" {
        return normalizePdsBase(ep)
      }
    }
    return nil
  }

  /// Resolves the HTTPS PDS XRPC base for a repo DID via PLC (`GET {plcBase}/{did}`).
  public static func resolvePdsBase(
    repoDid: String,
    plcBase: String,
    httpClient: HTTPClient,
    timeout: TimeAmount = .seconds(15),
    cache explicitCache: (any PDSResolutionCache)? = nil
  ) async throws -> String? {
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
        return validatedCachedEndpoint(endpoint)
      case .stale(let endpoint):
        guard let lease = try await cache.acquireLease(did: repoDid, ttl: 15) else {
          return validatedCachedEndpoint(endpoint)
        }
        heldLease = lease
      case .miss:
        if let lease = try await cache.acquireLease(did: repoDid, ttl: 15) {
          heldLease = lease
        } else if let contender = try await waitForContender(cache: cache, did: repoDid) {
          return validatedCachedEndpoint(contender)
        }
      }
    } catch {
      // Redis is an acceleration dependency. Resolution continues directly against PLC.
    }
    defer {
      if let heldLease {
        Task { await cache.releaseLease(heldLease) }
      }
    }

    let encoded = repoDid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoDid
    let root = normalizePdsBase(plcBase)
    var request = HTTPClientRequest(url: "\(root)/\(encoded)")
    request.headers.add(name: "Accept", value: "application/json")

    let response = try await httpClient.execute(request, timeout: timeout)

    // A throttled or broken PLC is not evidence that the DID has no PDS. Callers treat a nil base
    // as "this repo is unreachable" and drop the row, so caching a 429 as a negative would make
    // publications vanish from sidebars for the length of the TTL.
    guard response.status != .tooManyRequests, response.status.code < 500 else {
      throw ATProtoPdsResolutionUnavailable(status: response.status.code)
    }

    guard response.status == .ok else {
      try? await cache.storeUnresolved(did: repoDid, now: Date())
      return nil
    }

    let body = try await response.body.collect(upTo: 64 * 1024)
    guard
      let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
      let parsed = parsePdsEndpointFromPlcDoc(json),
      let base = validatedCachedEndpoint(parsed)
    else {
      try? await cache.storeUnresolved(did: repoDid, now: Date())
      return nil
    }

    try? await cache.storeResolved(did: repoDid, endpoint: base, now: Date())
    return base
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

  private static func validatedCachedEndpoint(_ endpoint: String?) -> String? {
    guard let endpoint else { return nil }
    let normalized = normalizePdsBase(endpoint)
    guard let components = URLComponents(string: normalized),
          components.scheme?.lowercased() == "https",
          components.host != nil,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil
    else { return nil }
    return normalized
  }

  /// `repo` must be a DID for PDS reads; resolves handles via public App View.
  public static func resolveRepoDid(
    handleOrDid: String,
    httpClient: HTTPClient,
    appViewBase: String = ATProtoPdsResolution.bskyAppViewPublic,
    timeout: TimeAmount = .seconds(15)
  ) async throws -> String? {
    let trimmed = handleOrDid.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "^@", with: "", options: .regularExpression)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("did:") { return trimmed }

    var c = URLComponents(string: "\(normalizePdsBase(appViewBase))/xrpc/com.atproto.identity.resolveHandle")!
    c.queryItems = [URLQueryItem(name: "handle", value: trimmed)]
    guard let url = c.url?.absoluteString else { return nil }

    var request = HTTPClientRequest(url: url)
    request.headers.add(name: "Accept", value: "application/json")

    let response = try await httpClient.execute(request, timeout: timeout)
    guard response.status == .ok else { return nil }

    let body = try await response.body.collect(upTo: 16 * 1024)
    guard
      let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
      let did = json["did"] as? String
    else { return nil }

    return did
  }
}
