import Foundation

enum PDSResolvedEndpointPolicy: Sendable {
  case publicHTTPS
  case localTesting
}

enum PDSResolvedEndpointValidator {
  private static let specialUseSuffixes = [
    ".alt",
    ".arpa",
    ".example",
    ".home.arpa",
    ".internal",
    ".invalid",
    ".local",
    ".localdomain",
    ".localhost",
    ".onion",
    ".test",
  ]

  private static let reservedExampleDomains = [
    "example.com",
    "example.net",
    "example.org",
  ]

  static func validatedBase(
    _ raw: String,
    policy: PDSResolvedEndpointPolicy
  ) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(),
      let rawHost = components.host?.lowercased(),
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else { return nil }

    let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
    guard !host.isEmpty else { return nil }

    let isLocalTestEndpoint = isLoopbackHost(host)
    switch policy {
    case .publicHTTPS:
      guard scheme == "https", isPublicHostname(host) else { return nil }
    case .localTesting:
      if isLocalTestEndpoint {
        guard scheme == "http" || scheme == "https" else { return nil }
      } else {
        guard scheme == "https", isPublicHostname(host) else { return nil }
      }
    }

    components.scheme = scheme
    components.host = host
    components.path = ""
    guard var normalized = components.url?.absoluteString else { return nil }
    while normalized.hasSuffix("/") { normalized.removeLast() }
    return normalized
  }

  private static func isPublicHostname(_ host: String) -> Bool {
    guard !isIPLiteral(host), !isLoopbackHost(host), host.count <= 253 else { return false }
    guard host.contains(".") else { return false }
    guard !specialUseSuffixes.contains(where: { host.hasSuffix($0) }) else { return false }
    guard
      !reservedExampleDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
    else { return false }

    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }
    return labels.allSatisfy { label in
      guard !label.isEmpty, label.count <= 63,
        label.first != "-", label.last != "-"
      else { return false }
      return label.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) || $0 == 45
      }
    }
  }

  private static func isLoopbackHost(_ host: String) -> Bool {
    if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
    guard let octets = ipv4Octets(host) else { return false }
    return octets[0] == 127
  }

  private static func isIPLiteral(_ host: String) -> Bool {
    host.contains(":") || ipv4Octets(host) != nil
  }

  private static func ipv4Octets(_ host: String) -> [UInt8]? {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var octets: [UInt8] = []
    octets.reserveCapacity(4)
    for part in parts {
      guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = UInt8(part) else {
        return nil
      }
      octets.append(value)
    }
    return octets
  }
}
