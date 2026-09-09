import Foundation

public struct ReadStateV2Fragment: Codable, Sendable, Equatable {
  public let operation: ReadStateOperation
  public let intentHash: String
  public let deviceId: String?
  public let deviceCounter: Int64?
  enum CodingKeys: String, CodingKey { case fragment, intentHash, deviceId, deviceCounter }

  public init(operation: ReadStateOperation, intentHash: String, deviceId: String? = nil, deviceCounter: Int64? = nil) throws {
    self.operation = operation; self.intentHash = intentHash; self.deviceId = deviceId; self.deviceCounter = deviceCounter
    try validate()
  }
  public init(from decoder: any Decoder) throws {
    try ReadStateV2RecordShape.fragment(decoder)
    operation = try ReadStateOperation(from: decoder)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard try container.decode(Bool.self, forKey: .fragment) else { throw ReadStateError.invalidRecord }
    intentHash = try container.decode(String.self, forKey: .intentHash)
    deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
    deviceCounter = try container.decodeIfPresent(Int64.self, forKey: .deviceCounter)
    try validate()
  }
  public func encode(to encoder: any Encoder) throws {
    try operation.encode(to: encoder)
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(true, forKey: .fragment); try container.encode(intentHash, forKey: .intentHash)
    try container.encodeIfPresent(deviceId, forKey: .deviceId); try container.encodeIfPresent(deviceCounter, forKey: .deviceCounter)
  }
  public func validate() throws {
    try ReadStateValidation.validate(operation)
    guard ReadStateV2RecordShape.hash(intentHash), (deviceId == nil) == (deviceCounter == nil) else { throw ReadStateError.invalidRecord }
    if let deviceId, let deviceCounter {
      guard ReadStateV2RecordShape.device(deviceId), (1...ReadStateValidation.maximumSequence).contains(deviceCounter) else { throw ReadStateError.invalidRecord }
    }
  }
}
