import AsyncHTTPClient
import Foundation
import NIOCore

/// Process-wide cache of PLC `#atproto_pds` lookups.
///
/// Every authenticated repo read resolves the repo's PDS before issuing its XRPC call, so an
/// uncached resolver doubles the request count of every read and points the extra half at a single
/// rate-limited host. A sidebar rebuild touching a few hundred distinct DIDs was issuing thousands
/// of PLC lookups per request.
///
/// Failures are cached only briefly, and transient upstream failures are not cached at all — see
/// `ATProtoPdsResolution.resolvePdsBase`.
actor PdsBaseResolutionCache {
  static let shared = PdsBaseResolutionCache()

  private var entries: [String: (base: String?, expiresAt: Date)] = [:]
  private static let resolvedTTL: TimeInterval = 30 * 60
  private static let unresolvedTTL: TimeInterval = 60

  /// Returns `.some(base)` on a cache hit (where `base` may itself be nil for a cached negative),
  /// and `nil` when the DID is not cached.
  func cached(_ did: String) -> (String?)? {
    guard let hit = entries[did], hit.expiresAt > Date() else { return nil }
    return .some(hit.base)
  }

  func store(_ did: String, base: String?) {
    let ttl = base == nil ? Self.unresolvedTTL : Self.resolvedTTL
    entries[did] = (base, Date().addingTimeInterval(ttl))
  }
}

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
    timeout: TimeAmount = .seconds(15)
  ) async throws -> String? {
    guard repoDid.hasPrefix("did:") else { return nil }

    if let hit = await PdsBaseResolutionCache.shared.cached(repoDid) { return hit }

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
      await PdsBaseResolutionCache.shared.store(repoDid, base: nil)
      return nil
    }

    let body = try await response.body.collect(upTo: 64 * 1024)
    guard
      let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
      let base = parsePdsEndpointFromPlcDoc(json)
    else {
      await PdsBaseResolutionCache.shared.store(repoDid, base: nil)
      return nil
    }

    await PdsBaseResolutionCache.shared.store(repoDid, base: base)
    return base
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
