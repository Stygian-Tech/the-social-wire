import Foundation

/// Immutable after publication. New operations prepend chunks and reuse the old chain.
public struct ReadStateChunk: Codable, Sendable, Equatable {
  public static let collection = "app.thesocialwire.readStateChunk"
  public let type: String
  public let version: Int
  public let operations: [ReadStateOperation]
  public let previous: ReadStateReference?
  public let allowsRepacking: Bool

  enum CodingKeys: String, CodingKey {
    case type = "$type"
    case version, operations, previous
  }

  public init(operations: [ReadStateOperation], previous: ReadStateReference?) {
    type = Self.collection
    version = 1
    self.operations = operations
    self.previous = previous
    allowsRepacking = true
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decode(String.self, forKey: .type)
    version = try container.decode(Int.self, forKey: .version)
    operations = try container.decode([ReadStateOperation].self, forKey: .operations)
    previous = try container.decodeIfPresent(ReadStateReference.self, forKey: .previous)
    allowsRepacking = try ReadStateRecordShape.knownChunk(decoder)
  }
}
