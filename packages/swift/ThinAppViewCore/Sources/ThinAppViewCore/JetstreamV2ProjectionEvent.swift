import Foundation

public enum JetstreamV2ProjectionEvent: Sendable, Equatable {
  case commit(Commit)
  case identity(Identity)
  case account(Account)
  case sync(Sync)

  public struct Commit: Sendable, Equatable {
    public let did: String
    public let sequence: Int64
    public let eventTime: Date
    public let operation: Operation
    public let collection: String
    public let rkey: String
    public let repoRev: String
    public let cid: String?
    public let recordJSON: Data?
  }

  public enum Operation: String, Sendable, Equatable {
    case create
    case update
    case delete
  }

  public struct Identity: Sendable, Equatable {
    public let did: String
    public let sequence: Int64
    public let eventTime: Date
    public let handle: String?
  }

  public struct Account: Sendable, Equatable {
    public let did: String
    public let sequence: Int64
    public let eventTime: Date
    public let active: Bool
    public let status: TapAccountStatus
  }

  public struct Sync: Sendable, Equatable {
    public let did: String
    public let sequence: Int64
    public let eventTime: Date
    public let repoRev: String
  }
}

public enum JetstreamV2ProjectionEventParseError: Error, Sendable, Equatable {
  case invalidJSON
  case invalidEnvelope
  case metadataMismatch
  case invalidCommit
  case invalidIdentity
  case invalidAccount
  case invalidSync
}

public enum JetstreamV2ProjectionEventParser {
  public static func parse(
    _ data: Data,
    expectedSequence: Int64,
    expectedKind: AppViewIngestionEventKind,
    expectedRepoDid: String
  ) throws -> JetstreamV2ProjectionEvent {
    guard
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let did = validDid(json["did"]),
      let sequence = int64(json["cursor"]),
      sequence >= 0,
      let timeMicroseconds = int64(json["time_us"]),
      timeMicroseconds >= 0,
      let rawKind = nonEmptyString(json["kind"]),
      let kind = AppViewIngestionEventKind(rawValue: rawKind)
    else {
      if (try? JSONSerialization.jsonObject(with: data)) == nil {
        throw JetstreamV2ProjectionEventParseError.invalidJSON
      }
      throw JetstreamV2ProjectionEventParseError.invalidEnvelope
    }
    guard sequence == expectedSequence, kind == expectedKind, did == expectedRepoDid else {
      throw JetstreamV2ProjectionEventParseError.metadataMismatch
    }
    let envelopeTime = Date(timeIntervalSince1970: TimeInterval(timeMicroseconds) / 1_000_000)

    switch kind {
    case .commit:
      guard
        let commit = json["commit"] as? [String: Any],
        let operationRaw = nonEmptyString(commit["operation"]),
        let operation = JetstreamV2ProjectionEvent.Operation(rawValue: operationRaw),
        let collection = nonEmptyString(commit["collection"]),
        let rkey = nonEmptyString(commit["rkey"]),
        let repoRev = nonEmptyString(commit["rev"])
      else { throw JetstreamV2ProjectionEventParseError.invalidCommit }
      let recordJSON: Data?
      if let record = commit["record"] {
        guard JSONSerialization.isValidJSONObject(record) else {
          throw JetstreamV2ProjectionEventParseError.invalidCommit
        }
        recordJSON = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
      } else {
        recordJSON = nil
      }
      guard operation == .delete || recordJSON != nil else {
        throw JetstreamV2ProjectionEventParseError.invalidCommit
      }
      return .commit(
        .init(
          did: did,
          sequence: sequence,
          eventTime: envelopeTime,
          operation: operation,
          collection: collection,
          rkey: rkey,
          repoRev: repoRev,
          cid: nonEmptyString(commit["cid"]),
          recordJSON: recordJSON
        )
      )

    case .identity:
      guard
        let identity = json["identity"] as? [String: Any],
        validDid(identity["did"]) == did,
        let identitySequence = int64(identity["seq"]),
        identitySequence >= 0,
        let eventTime = date(identity["time"])
      else { throw JetstreamV2ProjectionEventParseError.invalidIdentity }
      _ = identitySequence
      return .identity(
        .init(
          did: did,
          sequence: sequence,
          eventTime: eventTime,
          handle: nonEmptyString(identity["handle"])
        )
      )

    case .account:
      guard
        let account = json["account"] as? [String: Any],
        validDid(account["did"]) == did,
        let accountSequence = int64(account["seq"]),
        accountSequence >= 0,
        let active = account["active"] as? Bool,
        let eventTime = date(account["time"])
      else { throw JetstreamV2ProjectionEventParseError.invalidAccount }
      _ = accountSequence
      let status: TapAccountStatus
      if active {
        status = .active
      } else if let raw = nonEmptyString(account["status"]),
        let parsed = TapAccountStatus(rawValue: raw.lowercased())
      {
        status = parsed
      } else {
        status = .deactivated
      }
      return .account(
        .init(
          did: did,
          sequence: sequence,
          eventTime: eventTime,
          active: active,
          status: status
        )
      )

    case .sync:
      guard
        let sync = json["sync"] as? [String: Any],
        validDid(sync["did"]) == did,
        let syncSequence = int64(sync["seq"]),
        syncSequence >= 0,
        let repoRev = nonEmptyString(sync["rev"]),
        let eventTime = date(sync["time"])
      else { throw JetstreamV2ProjectionEventParseError.invalidSync }
      _ = syncSequence
      return .sync(
        .init(
          did: did,
          sequence: sequence,
          eventTime: eventTime,
          repoRev: repoRev
        )
      )
    }
  }

  private static func validDid(_ value: Any?) -> String? {
    guard let value = nonEmptyString(value), value.hasPrefix("did:") else { return nil }
    return value
  }

  private static func nonEmptyString(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func int64(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value) }
    return nil
  }

  private static func date(_ value: Any?) -> Date? {
    guard let raw = nonEmptyString(value) else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let parsed = fractional.date(from: raw) { return parsed }
    return ISO8601DateFormatter().date(from: raw)
  }
}
