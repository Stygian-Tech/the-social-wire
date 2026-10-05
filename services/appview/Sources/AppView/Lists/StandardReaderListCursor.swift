import Crypto
import Foundation
import Hummingbird

/// Continuation is scoped to the viewer, list membership, and read filter.
enum StandardReaderListCursor {
  private struct Payload: Codable {
    let fingerprint: String
    let continuation: String
  }

  static func fingerprint(viewerDid: String, list: StandardReaderListDTO, filter: String) -> String {
    let material = ([viewerDid, list.uri, filter] + list.publications + ["authors"] + list.users).joined(separator: "\n")
    return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func decode(_ raw: String?, fingerprint: String) throws -> String? {
    guard let raw else { return nil }
    guard raw.count <= 8192, let data = Data(base64Encoded: raw),
      let payload = try? JSONDecoder().decode(Payload.self, from: data),
      payload.fingerprint == fingerprint else {
      throw HTTPError(.badRequest, message: "List cursor does not match this viewer, list, or filter.")
    }
    return payload.continuation
  }

  static func encode(_ continuation: String?, fingerprint: String) -> String? {
    guard let continuation else { return nil }
    return (try? JSONEncoder().encode(Payload(fingerprint: fingerprint, continuation: continuation)))?.base64EncodedString()
  }
}
