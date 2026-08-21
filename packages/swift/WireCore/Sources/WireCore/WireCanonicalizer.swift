import Crypto
import Foundation

public enum WireCanonicalizer {
  public static let version = "canonical-url-v1"

  private static let trackingNames: Set<String> = [
    "dclid", "fbclid", "gclid", "igshid", "mc_cid", "mc_eid", "msclkid",
  ]

  public static func canonicalize(_ rawValue: String) -> WireCanonicalIdentity? {
    guard var components = URLComponents(string: rawValue),
      let rawScheme = components.scheme?.lowercased(),
      rawScheme == "http" || rawScheme == "https",
      let rawHost = components.host?.lowercased(),
      !rawHost.isEmpty,
      components.user == nil,
      components.password == nil
    else {
      return nil
    }

    components.scheme = "https"
    components.host = rawHost
    if components.port == 80 || components.port == 443 { components.port = nil }
    components.fragment = nil
    if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
    while components.percentEncodedPath.count > 1, components.percentEncodedPath.hasSuffix("/") {
      components.percentEncodedPath.removeLast()
    }
    components.queryItems = components.queryItems?
      .filter { item in
        let name = item.name.lowercased()
        return !name.hasPrefix("utm_") && !trackingNames.contains(name)
      }
      .sorted {
        if $0.name != $1.name { return $0.name < $1.name }
        return ($0.value ?? "") < ($1.value ?? "")
      }
    if components.queryItems?.isEmpty == true { components.queryItems = nil }

    guard let canonicalURL = components.url?.absoluteString else { return nil }
    let digest = SHA256.hash(data: Data(canonicalURL.utf8))
    let key = digest.map { String(format: "%02x", $0) }.joined()
    return WireCanonicalIdentity(canonicalKey: "url:\(key)", canonicalURL: canonicalURL)
  }
}
