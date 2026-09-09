import Foundation
import ReadStateCore

struct PDSReadStateFetchedRecord: Sendable {
  let uri: String
  let cid: String
  let json: Data

  func decode<T: Decodable>(viewerDid: String, collection: String, key: String) throws -> T {
    guard uri == "at://\(viewerDid)/\(collection)/\(key)" else { throw ReadStateError.invalidReference }
    try ReadStateRecordCID.verify(json: json, cid: cid)
    return try JSONDecoder().decode(T.self, from: json)
  }
}
