import Crypto
import Foundation

public struct SportsSelectionMutation: Sendable, Equatable {
  public let viewerDID: String
  public let recordKey: String
  public let action: String?
  public let reference: String?
  public let eventAt: Date
  public let repoRev: String
  public var isDeleted: Bool { action == nil }

  public static func parse(viewerDID: String, recordKey: String, operation: String,
    record: [String: Any], eventAt: Date, repoRev: String?) -> Self? {
    guard viewerDID.hasPrefix("did:"), recordKey.count == 64,
      recordKey.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
    if operation == "delete" {
      return Self(viewerDID: viewerDID, recordKey: recordKey, action: nil, reference: nil,
        eventAt: eventAt, repoRev: repoRev ?? "")
    }
    guard ["create", "update"].contains(operation),
      record["$type"] as? String == "app.thesocialwire.sports.selection",
      let action = record["action"] as? String, ["follow", "mute"].contains(action),
      let reference = record["reference"] as? String, !reference.isEmpty, reference.utf8.count <= 128
    else { return nil }
    let expected = SHA256.hash(data: Data(reference.utf8))
      .map { String(format: "%02x", $0) }.joined()
    guard expected == recordKey else { return nil }
    return Self(viewerDID: viewerDID, recordKey: recordKey, action: action, reference: reference,
      eventAt: eventAt, repoRev: repoRev ?? "")
  }
}
