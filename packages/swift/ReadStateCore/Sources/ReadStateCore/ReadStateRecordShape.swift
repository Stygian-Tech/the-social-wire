import Foundation

/// Unknown extension fields remain safe in immutable old chunks, but a typed
/// re-encode would discard them. Such generations must not be densely repacked.
enum ReadStateRecordShape {
  private struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  static func knownChunk(_ decoder: any Decoder) throws -> Bool {
    let container = try decoder.container(keyedBy: Key.self)
    guard known(container, keys: ["$type", "version", "operations", "previous"]) else { return false }
    if container.contains(Key("previous")), try !container.decodeNil(forKey: Key("previous")),
       try !reference(container.superDecoder(forKey: Key("previous"))) { return false }
    var operations = try container.nestedUnkeyedContainer(forKey: Key("operations"))
    while !operations.isAtEnd {
      let operation = try operations.superDecoder().container(keyedBy: Key.self)
      guard known(operation, keys: ["actionId", "sequence", "state", "actedAt", "selection",
        "boundaries", "subjectUris", "calendar"]) else { return false }
      if operation.contains(Key("calendar")), try !operation.decodeNil(forKey: Key("calendar")) {
        let calendar = try operation.nestedContainer(keyedBy: Key.self, forKey: Key("calendar"))
        guard known(calendar, keys: ["cutoff", "timeZone", "referenceDate"]) else { return false }
      }
      if operation.contains(Key("boundaries")), try !operation.decodeNil(forKey: Key("boundaries")) {
        var boundaries = try operation.nestedUnkeyedContainer(forKey: Key("boundaries"))
        while !boundaries.isAtEnd {
          let boundary = try boundaries.superDecoder().container(keyedBy: Key.self)
          guard known(boundary, keys: ["scope", "createdAt", "entryId"]) else { return false }
          let scope = try boundary.nestedContainer(keyedBy: Key.self, forKey: Key("scope"))
          guard known(scope, keys: ["publicationId", "authorDid", "publicationSiteKeys"]) else { return false }
        }
      }
    }
    return true
  }

  private static func reference(_ decoder: any Decoder) throws -> Bool {
    known(try decoder.container(keyedBy: Key.self), keys: ["uri", "cid"])
  }

  private static func known(_ container: KeyedDecodingContainer<Key>, keys: Set<String>) -> Bool {
    container.allKeys.allSatisfy { keys.contains($0.stringValue) }
  }
}
