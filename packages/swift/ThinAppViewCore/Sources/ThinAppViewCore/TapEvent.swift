import Foundation
import OperationsCore

public struct TapRecordEvent: Sendable, Equatable {
  public enum Action: String, Sendable, Equatable {
    case create
    case update
    case delete
  }

  public let id: Int64
  public let did: String
  public let rev: String
  public let collection: String
  public let rkey: String
  public let action: Action
  public let cid: String?
  public let recordJSON: Data?
  public let live: Bool
}

public struct TapIdentityEvent: Sendable, Equatable {
  public let id: Int64
  public let did: String
  public let handle: String
  public let isActive: Bool
  public let status: TapAccountStatus
}

public enum TapEvent: Sendable, Equatable {
  case record(TapRecordEvent)
  case identity(TapIdentityEvent)

  public var id: Int64 {
    switch self {
    case .record(let event): event.id
    case .identity(let event): event.id
    }
  }

  public var repoDid: String {
    switch self {
    case .record(let event): event.did
    case .identity(let event): event.did
    }
  }
}

public enum TapEventParseError: Error, CustomStringConvertible {
  case invalidJSON
  case invalidEnvelope
  case invalidRecord
  case invalidIdentity

  public var description: String {
    switch self {
    case .invalidJSON: "Tap event is not valid JSON."
    case .invalidEnvelope: "Tap event envelope is invalid."
    case .invalidRecord: "Tap record event is invalid."
    case .invalidIdentity: "Tap identity event is invalid."
    }
  }
}

public enum TapEventParser {
  public static func parse(_ text: String) throws -> TapEvent {
    guard
      let data = text.data(using: .utf8),
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw TapEventParseError.invalidJSON }
    guard
      let id = int64(json["id"]),
      id >= 0,
      let type = json["type"] as? String
    else { throw TapEventParseError.invalidEnvelope }

    switch type {
    case "record":
      guard
        let record = json["record"] as? [String: Any],
        let did = validDid(record["did"]),
        let rev = nonEmptyString(record["rev"]),
        let collection = nonEmptyString(record["collection"]),
        let rkey = nonEmptyString(record["rkey"]),
        let actionRaw = nonEmptyString(record["action"]),
        let action = TapRecordEvent.Action(rawValue: actionRaw),
        let live = record["live"] as? Bool
      else { throw TapEventParseError.invalidRecord }
      let recordJSON: Data?
      if let body = record["record"] {
        guard JSONSerialization.isValidJSONObject(body) else {
          throw TapEventParseError.invalidRecord
        }
        recordJSON = try JSONSerialization.data(withJSONObject: body)
      } else {
        recordJSON = nil
      }
      if action != .delete, recordJSON == nil {
        throw TapEventParseError.invalidRecord
      }
      return .record(
        TapRecordEvent(
          id: id,
          did: did,
          rev: rev,
          collection: collection,
          rkey: rkey,
          action: action,
          cid: nonEmptyString(record["cid"]),
          recordJSON: recordJSON,
          live: live
        )
      )

    case "identity":
      guard
        let identity = json["identity"] as? [String: Any],
        let did = validDid(identity["did"]),
        let handle = nonEmptyString(identity["handle"]),
        let isActive = (identity["isActive"] ?? identity["is_active"]) as? Bool,
        let statusRaw = nonEmptyString(identity["status"]),
        let status = TapAccountStatus(rawValue: statusRaw),
        isActive == status.isActive
      else { throw TapEventParseError.invalidIdentity }
      return .identity(
        TapIdentityEvent(
          id: id,
          did: did,
          handle: handle,
          isActive: isActive,
          status: status
        )
      )

    default:
      throw TapEventParseError.invalidEnvelope
    }
  }

  private static func int64(_ value: Any?) -> Int64? {
    switch value {
    case let value as Int64: value
    case let value as Int: Int64(value)
    case let value as NSNumber: value.int64Value
    default: nil
    }
  }

  private static func nonEmptyString(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func validDid(_ value: Any?) -> String? {
    guard let did = nonEmptyString(value), ATProtoRepositoryDIDValidator.isValid(did) else {
      return nil
    }
    return did
  }
}
