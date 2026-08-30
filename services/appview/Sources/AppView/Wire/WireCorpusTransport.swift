import Foundation

protocol WireCorpusTransport: Sendable {
  func get(target: String) async throws -> WireCorpusTransportResponse
  func post(target: String, body: Data) async throws -> WireCorpusTransportResponse
}

extension WireCorpusTransport {
  func post(target: String, body: Data) async throws -> WireCorpusTransportResponse {
    throw WireServingError.corpusContractMismatch
  }
}
