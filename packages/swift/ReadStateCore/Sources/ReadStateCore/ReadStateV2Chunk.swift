import Foundation

public struct ReadStateV2Chunk: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable { case state, devices, legacyReceipts }
  public let kind: Kind
  public let fragments: [ReadStateV2Fragment]
  public let deviceReceipts: [ReadStateDeviceReceipt]
  public let legacyReceipts: [ReadStateLegacyActionReceipt]
  public let previous: ReadStateReference?
  enum CodingKeys: String, CodingKey { case type = "$type"; case version, kind, fragments, receipts, previous }
  public init(fragments: [ReadStateV2Fragment], previous: ReadStateReference? = nil) { kind = .state; self.fragments = fragments; deviceReceipts = []; legacyReceipts = []; self.previous = previous }
  public init(devices: [ReadStateDeviceReceipt], previous: ReadStateReference? = nil) { kind = .devices; fragments = []; deviceReceipts = devices; legacyReceipts = []; self.previous = previous }
  public init(legacyReceipts: [ReadStateLegacyActionReceipt], previous: ReadStateReference? = nil) { kind = .legacyReceipts; fragments = []; deviceReceipts = []; self.legacyReceipts = legacyReceipts; self.previous = previous }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard try container.decode(String.self, forKey: .type) == ReadStateChunk.collection,
      try container.decode(Int.self, forKey: .version) == 2 else { throw ReadStateError.invalidRecord }
    kind = try container.decode(Kind.self, forKey: .kind)
    try ReadStateV2RecordShape.chunk(decoder, kind: kind)
    previous = try container.decodeIfPresent(ReadStateReference.self, forKey: .previous)
    fragments = kind == .state ? try container.decode([ReadStateV2Fragment].self, forKey: .fragments) : []
    deviceReceipts = kind == .devices ? try container.decode([ReadStateDeviceReceipt].self, forKey: .receipts) : []
    legacyReceipts = kind == .legacyReceipts ? try container.decode([ReadStateLegacyActionReceipt].self, forKey: .receipts) : []
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ReadStateChunk.collection, forKey: .type); try container.encode(2, forKey: .version)
    try container.encode(kind, forKey: .kind); try container.encodeIfPresent(previous, forKey: .previous)
    switch kind {
    case .state: try container.encode(fragments, forKey: .fragments)
    case .devices: try container.encode(deviceReceipts, forKey: .receipts)
    case .legacyReceipts: try container.encode(legacyReceipts, forKey: .receipts)
    }
  }
  public func replacingPrevious(_ reference: ReadStateReference?) -> Self {
    switch kind { case .state: .init(fragments: fragments, previous: reference)
    case .devices: .init(devices: deviceReceipts, previous: reference)
    case .legacyReceipts: .init(legacyReceipts: legacyReceipts, previous: reference) }
  }
  public func validate(viewerDid: String) throws {
    if let previous { try ReadStateValidation.validate(previous, viewerDid: viewerDid) }
    let count = fragments.count + deviceReceipts.count + legacyReceipts.count
    guard (1...128).contains(count) else { throw ReadStateError.invalidRecord }
    for fragment in fragments { try fragment.validate() }
    for receipt in deviceReceipts {
      guard ReadStateV2RecordShape.device(receipt.deviceId), (0...ReadStateValidation.maximumSequence).contains(receipt.committedCounter), ReadStateV2RecordShape.hash(receipt.prefixHash) else { throw ReadStateError.invalidRecord }
    }
    for receipt in legacyReceipts {
      guard !receipt.actionId.isEmpty, receipt.actionId.utf8.count <= 128,
        (1...ReadStateValidation.maximumSequence).contains(receipt.originalSequence), ReadStateV2RecordShape.hash(receipt.originalIntentHash) else { throw ReadStateError.invalidRecord }
    }
    try ReadStateValidation.validateSize(self)
  }
}
