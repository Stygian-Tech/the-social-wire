import Crypto
import Foundation

public struct FinanceSelectionMutation: Sendable, Equatable {
  public let viewerDID: String
  public let recordKey: String
  public let kind: String?
  public let reference: String?
  public let eventAt: Date
  public let repoRev: String
  public var isDeleted: Bool { kind == nil }

  public static func parse(viewerDID: String, recordKey: String, operation: String,
    record: [String: Any], eventAt: Date, repoRev: String?) -> Self? {
    guard viewerDID.hasPrefix("did:"), recordKey.count == 64,
      recordKey.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
    if operation == "delete" {
      return Self(viewerDID: viewerDID, recordKey: recordKey, kind: nil, reference: nil,
        eventAt: eventAt, repoRev: repoRev ?? "")
    }
    guard ["create", "update"].contains(operation),
      record["$type"] as? String == "app.thesocialwire.finance.selection",
      let kind = record["kind"] as? String, ["instrument", "sector"].contains(kind),
      let reference = record["reference"] as? String, !reference.isEmpty, reference.utf8.count <= 128
    else { return nil }
    let expected = SHA256.hash(data: Data("\(kind):\(reference)".utf8))
      .map { String(format: "%02x", $0) }.joined()
    guard expected == recordKey else { return nil }
    return Self(viewerDID: viewerDID, recordKey: recordKey, kind: kind, reference: reference,
      eventAt: eventAt, repoRev: repoRev ?? "")
  }
}
