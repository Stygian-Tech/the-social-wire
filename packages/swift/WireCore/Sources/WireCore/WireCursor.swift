public struct WireCursor: Codable, Equatable, Sendable {
  public var generationID: String
  public var language: String
  public var nextOrdinal: Int

  public init(generationID: String, language: String, nextOrdinal: Int) {
    self.generationID = generationID
    self.language = language
    self.nextOrdinal = nextOrdinal
  }
}
