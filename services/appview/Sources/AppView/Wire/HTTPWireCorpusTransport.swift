import AsyncHTTPClient
import Foundation
import WireCore

struct HTTPWireCorpusTransport: WireCorpusTransport {
  private let baseURL: String
  private let serviceID: String
  private let sharedSecret: String
  private let httpClient: HTTPClient

  init(config: WireCorpusRemoteConfig, httpClient: HTTPClient) {
    self.baseURL = config.baseURL
    self.serviceID = config.serviceID
    self.sharedSecret = config.sharedSecret
    self.httpClient = httpClient
  }

  func get(target: String) async throws -> WireCorpusTransportResponse {
    let trust = try WireCorpusServiceTrust.signedHeaders(
      secret: sharedSecret,
      serviceID: serviceID,
      method: "GET",
      target: target
    )
    var request = HTTPClientRequest(url: "\(baseURL)\(target)")
    request.method = .GET
    request.headers.add(name: "Accept", value: "application/json")
    request.headers.add(name: WireCorpusServiceTrust.serviceHeaderName, value: trust.serviceID)
    request.headers.add(name: WireCorpusServiceTrust.timestampHeaderName, value: trust.timestamp)
    request.headers.add(name: WireCorpusServiceTrust.nonceHeaderName, value: trust.nonce)
    request.headers.add(name: WireCorpusServiceTrust.signatureHeaderName, value: trust.signature)
    let response = try await httpClient.execute(request, timeout: .seconds(6))
    let body = try await response.body.collect(upTo: 8 * 1024 * 1024)
    return WireCorpusTransportResponse(
      statusCode: Int(response.status.code),
      contractVersion: response.headers.first(name: "X-Wire-Corpus-Contract").flatMap(Int.init),
      body: Data(buffer: body)
    )
  }

  func post(target: String, body: Data) async throws -> WireCorpusTransportResponse {
    let bodyDigest = WireCorpusServiceTrust.bodyDigest(body)
    let trust = try WireCorpusServiceTrust.signedHeaders(
      secret: sharedSecret,
      serviceID: serviceID,
      method: "POST",
      target: target,
      bodyDigest: bodyDigest
    )
    var request = HTTPClientRequest(url: "\(baseURL)\(target)")
    request.method = .POST
    request.headers.add(name: "Accept", value: "application/json")
    request.headers.add(name: "Content-Type", value: "application/json")
    request.headers.add(name: WireCorpusServiceTrust.serviceHeaderName, value: trust.serviceID)
    request.headers.add(name: WireCorpusServiceTrust.timestampHeaderName, value: trust.timestamp)
    request.headers.add(name: WireCorpusServiceTrust.nonceHeaderName, value: trust.nonce)
    request.headers.add(name: WireCorpusServiceTrust.signatureHeaderName, value: trust.signature)
    request.headers.add(name: WireCorpusServiceTrust.bodyDigestHeaderName, value: bodyDigest)
    request.body = .bytes(body)
    let response = try await httpClient.execute(request, timeout: .seconds(8))
    let responseBody = try await response.body.collect(upTo: 8 * 1_024 * 1_024)
    return WireCorpusTransportResponse(
      statusCode: Int(response.status.code),
      contractVersion: response.headers.first(name: "X-Wire-Corpus-Contract").flatMap(Int.init),
      body: Data(buffer: responseBody)
    )
  }
}
