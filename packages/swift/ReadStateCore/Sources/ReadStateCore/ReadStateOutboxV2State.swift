import Foundation

/// This envelope is atomically persisted with the existing fenced outbox file.
public struct ReadStateOutboxV2State: Codable, Sendable {
  public struct Action: Codable, Sendable {
    public let actionId: String
    public let counter: Int64
    public let intentHash: String
  }
  public var acknowledged: ReadStateDeviceReceipt
  public var nextCounter: Int64
  public var maintenance: ReadStateV2Publication?
  public init(viewerDid: String) throws {
    acknowledged = try ReadStateDeviceReceipt(viewerDid: viewerDid, deviceId: UUID().uuidString.lowercased())
    nextCounter = 1; maintenance = nil
  }
}
