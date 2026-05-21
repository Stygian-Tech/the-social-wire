import AsyncHTTPClient
import Foundation
import NIOCore

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
    let encoded = repoDid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoDid
    let root = normalizePdsBase(plcBase)
    var request = HTTPClientRequest(url: "\(root)/\(encoded)")
    request.headers.add(name: "Accept", value: "application/json")

    let response = try await httpClient.execute(request, timeout: timeout)
    guard response.status == .ok else { return nil }

    let body = try await response.body.collect(upTo: 64 * 1024)
    guard
      let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
      let base = parsePdsEndpointFromPlcDoc(json)
    else { return nil }

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
