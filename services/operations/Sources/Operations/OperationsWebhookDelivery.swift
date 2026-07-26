import AsyncHTTPClient
import Crypto
import Foundation
import Logging
import NIOCore
import OperationsCore

struct OperationsWebhookDelivery: Sendable {
  let url: String
  let secret: String
  let logger: Logger
  private let send: @Sendable (HTTPClientRequest) async throws -> Int

  init(url: String, secret: String, httpClient: HTTPClient, logger: Logger) {
    self.url = url
    self.secret = secret
    self.logger = logger
    self.send = { request in
      let response = try await httpClient.execute(request, timeout: .seconds(15))
      _ = try await response.body.collect(upTo: 64 * 1_024)
      return Int(response.status.code)
    }
  }

  init(
    url: String,
    secret: String,
    logger: Logger,
    send: @escaping @Sendable (HTTPClientRequest) async throws -> Int
  ) {
    self.url = url
    self.secret = secret
    self.logger = logger
    self.send = send
  }

  func deliver(_ alert: OperationsAlert) async throws {
    try await deliverOnce(alert)
  }

  private func deliverOnce(_ alert: OperationsAlert) async throws {
    let body = try JSONEncoder().encode(alert)
    let signature = HMAC<SHA256>.authenticationCode(
      for: body,
      using: SymmetricKey(data: Data(secret.utf8))
    ).map { String(format: "%02x", $0) }.joined()
    var request = HTTPClientRequest(url: url)
    request.method = .POST
    request.headers.add(name: "Content-Type", value: "application/json")
    request.headers.add(name: "X-Social-Wire-Signature", value: "sha256=\(signature)")
    request.body = .bytes(ByteBuffer(data: body))
    let statusCode = try await send(request)
    guard (200..<300).contains(statusCode) else {
      logger.warning("Operations alert webhook rejected", metadata: ["status_class": .string("non_2xx")])
      throw WebhookDeliveryError.rejected
    }
  }
}

enum WebhookDeliveryError: Error { case rejected }
