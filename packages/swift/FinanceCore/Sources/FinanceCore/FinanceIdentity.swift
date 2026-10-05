import Crypto
import Foundation

public enum FinanceIdentity {
  /// Provider-native identity, never the mutable ticker or a company name.
  public static func instrumentID(provider: String, nativeID: String) -> String {
    "fin_" + SHA256.hash(data: Data("\(provider):\(nativeID)".utf8)).prefix(16)
      .map { String(format: "%02x", $0) }.joined()
  }
  public static func selectionRecordKey(kind: String, id: String) -> String {
    SHA256.hash(data: Data("\(kind):\(id)".utf8)).map { String(format: "%02x", $0) }.joined()
  }
  public static func preferenceFingerprint(instrumentIDs: [String], sectorIDs: [String]) -> String {
    let value = (Set(instrumentIDs).sorted().map { "i:\($0)" }
      + Set(sectorIDs).sorted().map { "s:\($0)" }).joined(separator: "\n")
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
