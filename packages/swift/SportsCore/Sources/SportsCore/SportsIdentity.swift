import Crypto
import Foundation

public enum SportsIdentity {
  /// Seed identity is independent of provider keys, names and season membership.
  public static func entityID(seed: String) -> String {
    "sp_" + SHA256.hash(data: Data(seed.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
  }
  public static func selectionRecordKey(id: String) -> String {
    SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  public static func selectionRecordKey(action: String, id: String) -> String { selectionRecordKey(id: id) }
  public static func preferenceFingerprint(selections: [SportsSelection]) -> String {
    let value = Set(selections.map { $0.action + ":" + $0.reference }).sorted().joined(separator: "\n")
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
