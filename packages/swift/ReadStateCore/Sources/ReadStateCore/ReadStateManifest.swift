import Foundation

/// Replaced with compare-and-swap at the singleton record key `self`.
public struct ReadStateManifest: Codable, Sendable, Equatable {
  public static let collection = "app.thesocialwire.readState"
  public let type: String
  public let version: Int
  public let generation: String
  public let lastSequence: Int64
  public let head: ReadStateReference?
  public let revision: Int64?
  public let stateHead: ReadStateReference?
  public let devicesHead: ReadStateReference?
  public let legacyReceiptsHead: ReadStateReference?
  public let compactionVersion: Int?
  public var effectiveStateHead: ReadStateReference? { version == 2 ? stateHead : head }
  public var effectiveRevision: Int64 { revision ?? lastSequence }
  public let extensions: [String: ReadStateJSONValue]

  enum CodingKeys: String, CodingKey {
    case type = "$type"
    case version, generation, lastSequence, head, revision, stateHead, devicesHead, legacyReceiptsHead, compactionVersion
  }

  public init(generation: String, lastSequence: Int64, head: ReadStateReference?,
              extensions: [String: ReadStateJSONValue] = [:]) {
    type = Self.collection
    version = 1
    self.generation = generation
    self.lastSequence = lastSequence
    self.head = head
    revision = nil; stateHead = nil; devicesHead = nil; legacyReceiptsHead = nil; compactionVersion = nil
    self.extensions = extensions.filter { CodingKeys(rawValue: $0.key) == nil }
  }

  public init(generation: String, revision: Int64, lastSequence: Int64,
    stateHead: ReadStateReference?, devicesHead: ReadStateReference?, legacyReceiptsHead: ReadStateReference?) {
    type = Self.collection; version = 2; self.generation = generation; self.revision = revision
    self.lastSequence = lastSequence; head = nil; self.stateHead = stateHead
    self.devicesHead = devicesHead; self.legacyReceiptsHead = legacyReceiptsHead
    compactionVersion = 1; extensions = [:]
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decode(String.self, forKey: .type)
    version = try container.decode(Int.self, forKey: .version)
    generation = try container.decode(String.self, forKey: .generation)
    lastSequence = try container.decode(Int64.self, forKey: .lastSequence)
    head = try container.decodeIfPresent(ReadStateReference.self, forKey: .head)
    revision = try container.decodeIfPresent(Int64.self, forKey: .revision)
    stateHead = try container.decodeIfPresent(ReadStateReference.self, forKey: .stateHead)
    devicesHead = try container.decodeIfPresent(ReadStateReference.self, forKey: .devicesHead)
    legacyReceiptsHead = try container.decodeIfPresent(ReadStateReference.self, forKey: .legacyReceiptsHead)
    compactionVersion = try container.decodeIfPresent(Int.self, forKey: .compactionVersion)
    if version == 2 { try ReadStateV2RecordShape.manifest(decoder) }
    let values = try decoder.container(keyedBy: ExtensionKey.self)
    var extensions: [String: ReadStateJSONValue] = [:]
    for key in values.allKeys where CodingKeys(rawValue: key.stringValue) == nil {
      extensions[key.stringValue] = try values.decode(ReadStateJSONValue.self, forKey: key)
    }
    self.extensions = extensions
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    try container.encode(version, forKey: .version)
    try container.encode(generation, forKey: .generation)
    try container.encode(lastSequence, forKey: .lastSequence)
    try container.encodeIfPresent(head, forKey: .head)
    try container.encodeIfPresent(revision, forKey: .revision)
    try container.encodeIfPresent(stateHead, forKey: .stateHead)
    try container.encodeIfPresent(devicesHead, forKey: .devicesHead)
    try container.encodeIfPresent(legacyReceiptsHead, forKey: .legacyReceiptsHead)
    try container.encodeIfPresent(compactionVersion, forKey: .compactionVersion)
    var values = encoder.container(keyedBy: ExtensionKey.self)
    for (key, value) in extensions where CodingKeys(rawValue: key) == nil {
      try values.encode(value, forKey: ExtensionKey(stringValue: key)!)
    }
  }

  private struct ExtensionKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
}
