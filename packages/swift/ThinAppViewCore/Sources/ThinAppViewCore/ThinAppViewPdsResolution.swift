import AsyncHTTPClient
import Foundation

enum ThinAppViewPdsResolution {
  static func resolvePdsBase(
    repoDid: String,
    plcBase: String,
    httpClient: HTTPClient
  ) async throws -> String? {
    guard repoDid.hasPrefix("did:") else { return nil }
    let encoded = repoDid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoDid
    var root = plcBase.trimmingCharacters(in: .whitespacesAndNewlines)
    while root.hasSuffix("/") { root.removeLast() }

    var request = HTTPClientRequest(url: "\(root)/\(encoded)")
    request.headers.add(name: "Accept", value: "application/json")
    let response = try await httpClient.execute(request, timeout: .seconds(15))
    guard response.status == .ok else { return nil }

    let body = try await response.body.collect(upTo: 64 * 1024)
    guard
      let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
      let services = json["service"] as? [[String: Any]]
    else { return nil }

    for service in services {
      let id = service["id"] as? String
      let type = service["type"] as? String
      guard let endpoint = service["serviceEndpoint"] as? String else { continue }
      if id == "#atproto_pds" || type == "AtprotoPersonalDataServer" {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return base
      }
    }
    return nil
  }
}
