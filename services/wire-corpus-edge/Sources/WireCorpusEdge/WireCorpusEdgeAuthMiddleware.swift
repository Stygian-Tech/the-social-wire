import Foundation
import HTTPTypes
import Hummingbird
import Logging
import WireCore

struct WireCorpusEdgeAuthMiddleware: RouterMiddleware {
  typealias Context = WireCorpusEdgeRequestContext

  private static let forbiddenHeaderNames = [
    "Authorization",
    "Cookie",
    "DPoP",
    "X-ATProto-Upstream-DPoP",
    "X-Wire-Moderation-DPoP",
    "X-SocialWire-Gateway-DID",
    "X-SocialWire-Gateway-Timestamp",
    "X-SocialWire-Gateway-Signature",
  ]

  let secret: String
  let allowedServiceID: String
  let replayGuard: WireCorpusReplayGuard
  let logger: Logger

  func handle(
    _ request: Request,
    context: WireCorpusEdgeRequestContext,
    next: (Request, WireCorpusEdgeRequestContext) async throws -> Response
  ) async throws -> Response {
    guard !Self.forbiddenHeaderNames.contains(where: { rawName in
      guard let name = HTTPField.Name(rawName) else { return false }
      return request.headers[name] != nil
    }) else {
      logger.warning("The Wire Corpus Edge rejected viewer-scoped headers")
      throw WireCorpusEdgeRequestError.unauthorized
    }
    guard
      let serviceName = HTTPField.Name(WireCorpusServiceTrust.serviceHeaderName),
      let timestampName = HTTPField.Name(WireCorpusServiceTrust.timestampHeaderName),
      let nonceName = HTTPField.Name(WireCorpusServiceTrust.nonceHeaderName),
      let signatureName = HTTPField.Name(WireCorpusServiceTrust.signatureHeaderName),
      let serviceID = request.headers[serviceName],
      let timestamp = request.headers[timestampName],
      let nonce = request.headers[nonceName],
      let signature = request.headers[signatureName]
    else {
      throw WireCorpusEdgeRequestError.unauthorized
    }
    let target = Self.target(request)
    let bodyDigest = HTTPField.Name(WireCorpusServiceTrust.bodyDigestHeaderName)
      .flatMap { request.headers[$0] }
    let now = Date()
    do {
      try WireCorpusServiceTrust.verify(
        secret: secret,
        expectedServiceID: allowedServiceID,
        presentedServiceID: serviceID,
        method: request.method.rawValue,
        target: target,
        timestamp: timestamp,
        nonce: nonce,
        signature: signature,
        bodyDigest: bodyDigest,
        now: now
      )
    } catch {
      logger.warning("The Wire Corpus Edge rejected invalid dedicated service trust")
      throw WireCorpusEdgeRequestError.unauthorized
    }
    guard await replayGuard.consume(nonce: nonce, now: now) else {
      logger.warning("The Wire Corpus Edge rejected a replayed or over-capacity request")
      throw WireCorpusEdgeRequestError.unauthorized
    }
    return try await next(request, context)
  }

  static func target(_ request: Request) -> String {
    guard let query = request.uri.query, !query.isEmpty else { return request.uri.path }
    return "\(request.uri.path)?\(query)"
  }
}
