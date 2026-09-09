import Foundation

/// V2 rewrites are closed to unknown nested semantics and reference roots.
enum ReadStateV2RecordShape {
  static func object(_ value: ReadStateJSONValue, keys: Set<String>) throws -> [String: ReadStateJSONValue] {
    guard case .object(let object) = value, Set(object.keys).isSubset(of: keys) else { throw ReadStateError.invalidRecord }
    return object
  }
  static func reference(_ value: ReadStateJSONValue?) throws {
    if let value, value != .null { _ = try object(value, keys: ["uri", "cid"]) }
  }
  static func manifest(_ decoder: any Decoder) throws {
    let value = try object(ReadStateJSONValue(from: decoder), keys: ["$type", "version", "generation", "revision", "lastSequence", "stateHead", "devicesHead", "legacyReceiptsHead", "compactionVersion"])
    for key in ["stateHead", "devicesHead", "legacyReceiptsHead"] { try reference(value[key]) }
  }
  static func fragment(_ decoder: any Decoder) throws {
    let value = try object(ReadStateJSONValue(from: decoder), keys: ["actionId", "sequence", "state", "actedAt", "selection", "subjectUris", "boundaries", "calendar", "fragment", "intentHash", "deviceId", "deviceCounter"])
    if let calendar = value["calendar"], calendar != .null { _ = try object(calendar, keys: ["cutoff", "timeZone", "referenceDate"]) }
    if case .array(let boundaries) = value["boundaries"] {
      for boundary in boundaries {
        let boundary = try object(boundary, keys: ["scope", "createdAt", "entryId"])
        _ = try object(boundary["scope"] ?? .null, keys: ["publicationId", "authorDid", "publicationSiteKeys"])
      }
    }
  }
  static func chunk(_ decoder: any Decoder, kind: ReadStateV2Chunk.Kind) throws {
    let value = try object(ReadStateJSONValue(from: decoder), keys: ["$type", "version", "kind", kind == .state ? "fragments" : "receipts", "previous"])
    try reference(value["previous"])
    if case .array(let receipts) = value["receipts"] {
      for receipt in receipts { _ = try object(receipt, keys: kind == .devices
        ? ["deviceId", "committedCounter", "prefixHash"] : ["actionId", "originalSequence", "originalIntentHash"]) }
    }
  }
  static func hash(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  static func device(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
}
