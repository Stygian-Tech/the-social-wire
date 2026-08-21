import Foundation

struct WireCorpusTransportResponse: Sendable {
  let statusCode: Int
  let contractVersion: Int?
  let body: Data
}
