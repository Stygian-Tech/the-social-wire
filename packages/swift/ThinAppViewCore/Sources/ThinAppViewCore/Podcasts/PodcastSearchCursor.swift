import Foundation

struct PodcastSearchCursor: Codable {
  var binding: String
  var entity: Int
  var id: String

  static func decode(_ value: String?, binding: String) throws -> Self? {
    guard let value else { return nil }
    guard let data = Data(base64Encoded: value), let decoded = try? JSONDecoder().decode(Self.self, from: data),
      decoded.binding == binding, [0, 1].contains(decoded.entity), decoded.id.count <= 2048
    else { throw PodcastStoreError.invalidRequest }
    return decoded
  }

  func encoded() throws -> String { try JSONEncoder().encode(self).base64EncodedString() }
}
