import Foundation

enum WirePublicEndpointValidator {
  private static let blockedSuffixes = [
    ".alt", ".arpa", ".example", ".home.arpa", ".internal", ".invalid", ".local",
    ".localdomain", ".localhost", ".onion", ".test",
  ]
  private static let blockedExamples = ["example.com", "example.net", "example.org"]

  static func validatedBase(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
      components.scheme?.lowercased() == "https",
      let rawHost = components.host?.lowercased(),
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else { return nil }
    let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
    guard isPublicHostname(host) else { return nil }
    components.scheme = "https"
    components.host = host
    components.path = ""
    guard var normalized = components.url?.absoluteString else { return nil }
    while normalized.hasSuffix("/") { normalized.removeLast() }
    return normalized
  }

  static func isPublicHostname(_ host: String) -> Bool {
    guard !host.isEmpty, host.count <= 253, host.contains("."), !isIPLiteral(host) else {
      return false
    }
    guard !blockedSuffixes.contains(where: host.hasSuffix) else { return false }
    guard !blockedExamples.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else {
      return false
    }
    return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
      !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
        && label.utf8.allSatisfy {
          ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) || $0 == 45
        }
    }
  }

  private static func isIPLiteral(_ host: String) -> Bool {
    if host.contains(":") { return true }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && UInt8($0) != nil }
  }
}
