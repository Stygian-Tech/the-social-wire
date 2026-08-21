public struct WireCorpusServiceHeaders: Equatable, Sendable {
  public let serviceID: String
  public let timestamp: String
  public let nonce: String
  public let signature: String

  public init(serviceID: String, timestamp: String, nonce: String, signature: String) {
    self.serviceID = serviceID
    self.timestamp = timestamp
    self.nonce = nonce
    self.signature = signature
  }
}
