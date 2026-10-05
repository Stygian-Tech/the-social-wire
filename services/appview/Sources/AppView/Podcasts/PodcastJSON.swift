import Foundation
import Hummingbird
import NIOCore

enum PodcastJSON {
  static func string(_ value: [String: String]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
  }
  static func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  static func response(_ json: String, status: HTTPResponse.Status = .ok) -> Response {
    Response(
      status: status, headers: [.contentType: "application/json"],
      body: .init(byteBuffer: ByteBuffer(string: json)))
  }
}
