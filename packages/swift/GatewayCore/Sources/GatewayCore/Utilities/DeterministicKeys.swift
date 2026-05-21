import Crypto
import Foundation

public enum DeterministicKeys {
  public static let preferencesRKey = "self"

  public static func generateTID() -> String {
    let ms = UInt64(Date().timeIntervalSince1970 * 1000)
    return String(ms, radix: 32).lowercased()
  }

  public static func entryReadStateRKey(subjectURI: String) -> String {
    let digest = SHA256.hash(data: Data(subjectURI.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
