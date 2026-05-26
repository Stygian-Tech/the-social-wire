import Crypto
import Foundation

public enum DeterministicKeys {
  public static let preferencesRKey = "self"

  public static func generateTID() -> String {
    let ms = UInt64(Date().timeIntervalSince1970 * 1000)
    return String(ms, radix: 32).lowercased()
  }

  /// Deterministic `com.thesocialwire.entryReadState` rkey — full RFC 4648 base32 (uppercase), SHA-256(subjectURI).
  public static func entryReadStateRKey(subjectURI: String) -> String {
    digestKey(for: subjectURI)
  }

  /// Legacy gateway hex read-state keys before base32 parity with L@tr / web clients.
  public static func legacyHexEntryReadStateRKey(subjectURI: String) -> String {
    let digest = SHA256.hash(data: Data(subjectURI.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

  private static func digestKey(for text: String) -> String {
    let hash = SHA256.hash(data: Data(text.utf8))
    return encodeBase32(Array(hash))
  }

  private static func encodeBase32(_ buffer: [UInt8]) -> String {
    var bits = 0
    var value = 0
    var out = ""
    for byte in buffer {
      value = (value << 8) | Int(byte)
      bits += 8
      while bits >= 5 {
        out.append(base32Alphabet[(value >> (bits - 5)) & 31])
        bits -= 5
      }
    }
    if bits > 0 {
      out.append(base32Alphabet[(value << (5 - bits)) & 31])
    }
    return out
  }
}
