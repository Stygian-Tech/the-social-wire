import Foundation

/// Strictly validates repository DIDs accepted by operational recovery.
///
/// Recovery intentionally supports only PLC repositories and public `did:web`
/// repositories. Synthetic identities and network-local hosts must never enter a
/// signed dry-run because the worker cannot safely or deterministically resolve them.
public enum ATProtoRepositoryDIDValidator {
  public static func isValid(_ candidate: String) -> Bool {
    guard candidate == candidate.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return false
    }
    if candidate.hasPrefix("did:plc:") {
      return isValidPLC(String(candidate.dropFirst("did:plc:".count)))
    }
    if candidate.hasPrefix("did:web:") {
      return isValidWeb(String(candidate.dropFirst("did:web:".count)), fullDID: candidate)
    }
    return false
  }

  private static func isValidPLC(_ identifier: String) -> Bool {
    guard identifier.count == 24 else { return false }
    return identifier.unicodeScalars.allSatisfy {
      ($0.value >= 97 && $0.value <= 122) || ($0.value >= 50 && $0.value <= 55)
    }
  }

  private static func isValidWeb(_ identifier: String, fullDID: String) -> Bool {
    guard fullDID.lowercased() != "did:web:skyreader.rss" else { return false }
    let segments = identifier.split(separator: ":", omittingEmptySubsequences: false)
    guard let first = segments.first, !first.isEmpty else { return false }
    let host = String(first).lowercased()
    guard isPublicHostname(host) else { return false }
    return segments.dropFirst().allSatisfy { isSafePathSegment(String($0)) }
  }

  private static func isPublicHostname(_ host: String) -> Bool {
    guard host.count <= 253, host.contains("."),
      !host.contains("%"), !host.contains("@"), !host.contains("/"),
      !host.contains("\\"), !host.contains("[") && !host.contains("]")
    else { return false }

    if isIPv4Literal(host) || host.contains(":") { return false }

    let blockedExact: Set<String> = [
      "localhost", "example.com", "example.net", "example.org",
    ]
    if blockedExact.contains(host) { return false }
    let blockedSuffixes = [
      ".localhost", ".local", ".internal", ".home", ".lan", ".test", ".invalid",
      ".example", ".onion", ".arpa",
    ]
    if blockedSuffixes.contains(where: host.hasSuffix) { return false }

    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }
    return labels.allSatisfy { label in
      guard !label.isEmpty, label.count <= 63, label.first != "-", label.last != "-" else {
        return false
      }
      return label.unicodeScalars.allSatisfy {
        ($0.value >= 97 && $0.value <= 122)
          || ($0.value >= 48 && $0.value <= 57)
          || $0.value == 45
      }
    }
  }

  private static func isIPv4Literal(_ host: String) -> Bool {
    let octets = host.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return false }
    return octets.allSatisfy { octet in
      guard !octet.isEmpty, octet.count <= 3,
        octet.allSatisfy({ $0.isNumber }), let value = Int(octet)
      else { return false }
      return (0...255).contains(value)
    }
  }

  private static func isSafePathSegment(_ segment: String) -> Bool {
    guard !segment.isEmpty else { return false }
    let scalars = Array(segment.unicodeScalars)
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      if scalar.value == 37 {
        guard index + 2 < scalars.count, isHex(scalars[index + 1]), isHex(scalars[index + 2]) else {
          return false
        }
        index += 3
        continue
      }
      let allowed = (scalar.value >= 65 && scalar.value <= 90)
        || (scalar.value >= 97 && scalar.value <= 122)
        || (scalar.value >= 48 && scalar.value <= 57)
        || [45, 46, 95, 126].contains(scalar.value)
      guard allowed else { return false }
      index += 1
    }
    return true
  }

  private static func isHex(_ scalar: Unicode.Scalar) -> Bool {
    (scalar.value >= 48 && scalar.value <= 57)
      || (scalar.value >= 65 && scalar.value <= 70)
      || (scalar.value >= 97 && scalar.value <= 102)
  }
}
