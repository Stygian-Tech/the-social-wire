import AsyncHTTPClient
import Foundation
import Hummingbird
import JWTKit
import Logging

/// Verifies ATProto OAuth access JWTs (`issuer` metadata → JWKS) using JWTKit's `JWTKeyCollection`.
enum OAuthAccessTokenVerifier {
  /// Cryptographically verified JWT access token slice used for **`AuthContext`** + optional first-party gateway binding.
  struct VerifiedAccessToken: Sendable {
    let did: String
    /// RFC 9449 **`cnf.jkt`** thumbprint binding (when issuer emits confirmation).
    let cnfJkt: String?
    let clientIdClaim: String?
    let azpClaim: String?
    let audiences: [String]
  }

  struct AccessClaims: JWTPayload {
    struct CnfClaims: Codable {
      /// RFC 8707 **JSON Web Thumbprint confirmation** identifying the demonstrated DPoP key.
      var jkt: String?
    }

    var iss: IssuerClaim?
    var sub: SubjectClaim
    var exp: ExpirationClaim
    var cnf: CnfClaims?

    func verify(using _: some JWTAlgorithm) throws {
      try exp.verifyNotExpired()
    }
  }

  enum VerifyError: Error {
    case missingIssuerClaim
    case unsupportedIssuerForm
    case jwksFetch(Int?)
    case jwksMissing
    case plcFetch(Int?)
    case noJwksCandidates
    case signatureRejected
  }

  /// Cryptographically verifies the access JWT, returning DID + **`cnf.jkt`** plus optional **`client_id`/`azp`/`aud`** claims.
  static func verify(
    accessTokenJWT: String,
    httpClient: HTTPClient,
    plcURL: String,
    logger: Logger
  )
    async throws -> VerifiedAccessToken
  {
    let unverifiedColl = JWTKeyCollection()
    let payload: AccessClaims = try await unverifiedColl.unverified(accessTokenJWT, as: AccessClaims.self)

    guard let issuerClaim = payload.iss?.value, !issuerClaim.isEmpty else {
      throw VerifyError.missingIssuerClaim
    }

    let baseCandidates: [String]
    if issuerClaim.hasPrefix("http://") || issuerClaim.hasPrefix("https://") {
      baseCandidates = issuerBaseVariants(for: issuerClaim).uniqueStable()
    } else if issuerClaim.hasPrefix("did:"),
              let didBases =
              try await issuerBasesFromDid(did: issuerClaim, plcURL: plcURL, httpClient: httpClient),
              !didBases.isEmpty {
      baseCandidates = didBases.uniqueStable()
    } else {
      throw VerifyError.unsupportedIssuerForm
    }

    let jwksTargets = try await collectJwksURLs(httpClient: httpClient, issuerBases: baseCandidates)
    guard !jwksTargets.isEmpty else { throw VerifyError.noJwksCandidates }

    logger.debug("JWKS probing order", metadata: ["jwks": .string(jwksTargets.joined(separator: " | "))])

    var probeError: Error = VerifyError.signatureRejected

    for target in jwksTargets {
      guard let probeURL = URL(string: target) else { continue }

      var probeRequest = HTTPClientRequest(url: probeURL.absoluteString)
      probeRequest.headers.add(name: "Accept", value: "application/json")

      let jwksResponse = try await httpClient.execute(probeRequest, timeout: .seconds(10))
      guard jwksResponse.status == .ok else {
        probeError = VerifyError.jwksFetch(Int(jwksResponse.status.code))
        continue
      }

      let jwksBlob = try await jwksResponse.body.collect(upTo: 512 * 1024)
      let decodedJWKSString = String(buffer: jwksBlob)
      guard !decodedJWKSString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        probeError = VerifyError.jwksMissing
        continue
      }

      let signers = JWTKeyCollection()
      do {
        try await signers.add(jwksJSON: decodedJWKSString)
      } catch {
        probeError = error
        continue
      }

      do {
        let verified = try await signers.verify(accessTokenJWT, as: AccessClaims.self, iteratingKeys: true)
        let subject = verified.sub.value
        guard subject.hasPrefix("did:") else {
          throw HTTPError(.unauthorized, message: "`sub` must be an ATProto DID")
        }
        let rawJkt = verified.cnf?.jkt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let thumb = (rawJkt?.isEmpty == false) ? rawJkt : nil
        let extra = Self.extractRegisteredClientSignals(fromJWT: accessTokenJWT)
        return VerifiedAccessToken(
          did: subject,
          cnfJkt: thumb,
          clientIdClaim: extra.clientId,
          azpClaim: extra.azp,
          audiences: extra.audiences
        )
      } catch {
        probeError = error
        continue
      }
    }

    throw probeError
  }

  private static func trimmedNonempty(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  /// Best-effort parse of JWT JSON payload (**after** JWKS verification) — ATProto issuer-specific claim spelling.
  private static func extractRegisteredClientSignals(fromJWT jwt: String)
    -> (clientId: String?, azp: String?, audiences: [String])
  {
    let segments = jwt.split(separator: ".")
    guard segments.count >= 2 else {
      return (clientId: nil, azp: nil, audiences: [])
    }

    guard let payloadData = jwtPayloadData(base64URLEncoded: String(segments[1])) else {
      return (clientId: nil, azp: nil, audiences: [])
    }

    guard let obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
      return (clientId: nil, azp: nil, audiences: [])
    }

    let clientTrimmed = trimmedNonempty(obj["client_id"] as? String)
      ?? trimmedNonempty(obj["clientId"] as? String)

    let azpTrimmed = trimmedNonempty(obj["azp"] as? String)

    var audiences: [String] = []

    if let single = obj["aud"] as? String {
      audiences = [single]
    } else if let multi = obj["aud"] as? [String] {
      audiences = multi
    }

    return (
      clientId: clientTrimmed,
      azp: azpTrimmed,
      audiences: audiences
    )
  }

  /// RFC 7519 Base64URL (no padding) → `Data`.
  private static func jwtPayloadData(base64URLEncoded: String) -> Data? {
    var copy = base64URLEncoded
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")

    let paddingLength = (4 - copy.count % 4) % 4
    if paddingLength > 0 {
      copy.append(String(repeating: "=", count: paddingLength))
    }

    guard let data = Data(base64Encoded: copy) else {
      return nil
    }

    return data
  }

  private static func collectJwksURLs(
    httpClient: HTTPClient,
    issuerBases: [String]
  ) async throws -> [String] {
    var accumulator: [String] = []

    outer: for base in issuerBases {
      let sanitizedBase = stripTrailingSlash(base)

      for suffix in [
        "/.well-known/oauth-authorization-server",
        "/.well-known/openid-configuration",
      ] {
        guard let probe = URL(string: sanitizedBase + suffix) else { continue }

        var request = HTTPClientRequest(url: probe.absoluteString)
        request.headers.add(name: "Accept", value: "application/json")

        let response = try await httpClient.execute(request, timeout: .seconds(10))
        guard response.status == .ok else { continue }

        let blob = try await response.body.collect(upTo: 64 * 1024)
        guard
          let decoded = try? JSONSerialization.jsonObject(with: Data(buffer: blob)) as? [String: Any],
          let jwks = decoded["jwks_uri"] as? String
        else {
          continue
        }

        let normalizedJWKSURI = normalizeRelativeJWKSURI(jwks, bases: issuerBases)
        accumulator.append(normalizedJWKSURI)
        continue outer
      }

      accumulator.append(sanitizedBase + "/jwt/jwks")
      accumulator.append(sanitizedBase + "/oauth/jwks")
    }

    return accumulator.uniqueStable()
  }

  private static func issuerBasesFromDid(did: String, plcURL: String, httpClient: HTTPClient) async throws
    -> [String]? {
    let encodedDid = did.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? did
    let plcDirectoryRoot = stripTrailingSlash(ATProtoPdsResolution.normalizePdsBase(plcURL))

    var fetch = HTTPClientRequest(url: "\(plcDirectoryRoot)/\(encodedDid)")
    fetch.headers.add(name: "Accept", value: "application/json")

    let plcResponse = try await httpClient.execute(fetch, timeout: .seconds(10))
    guard plcResponse.status == .ok else {
      throw VerifyError.plcFetch(Int(plcResponse.status.code))
    }

    let plcBody = try await plcResponse.body.collect(upTo: 256 * 1024)
    guard
      let plcDocument = try? JSONSerialization.jsonObject(with: Data(buffer: plcBody)) as? [String: Any]
    else {
      return nil
    }

    var bases: [String] = []

    if let resolvedPdsEndpoint = ATProtoPdsResolution.parsePdsEndpointFromPlcDoc(plcDocument) {
      bases.append(contentsOf: issuerBaseVariants(for: resolvedPdsEndpoint))
    }

    if let services = plcDocument["service"] as? [[String: Any]] {
      for service in services {
        guard let endpoint = service["serviceEndpoint"] as? String else { continue }
        let cleaned = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.hasPrefix("https://") else { continue }

        let lexicalType = ((service["type"] as? String) ?? "").lowercased()

        guard
          lexicalType.contains("oauth") || lexicalType.contains("openid") || lexicalType.contains(
            "authserver"
          )
        else {
          continue
        }
        bases.append(contentsOf: issuerBaseVariants(for: cleaned))
      }
    }

    guard !bases.isEmpty else { return nil }
    return bases.uniqueStable()
  }

  /// Collapses relative `jwks_uri` discoveries using the probing issuer prefixes (scheme/host aware).
  private static func normalizeRelativeJWKSURI(_ raw: String, bases: [String]) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return raw
    }

    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
      return trimmed
    }

    guard let ancestor = bases.first.flatMap(URL.init(string:)),
          var components = URLComponents(url: ancestor, resolvingAgainstBaseURL: false)
    else {
      return trimmed
    }

    if trimmed.hasPrefix("//") {
      let ancestorScheme = components.scheme ?? "https"
      return "\(ancestorScheme):\(trimmed)"
    }

    if trimmed.hasPrefix("/") {
      components.path = trimmed
      components.query = nil
      components.fragment = nil
      return components.url?.absoluteString ?? trimmed
    }

    components.query = nil
    components.fragment = nil

    let child = trimmingLeadingSlash(trimmed)

    guard !child.isEmpty else {
      return trimmed
    }

    if components.path.hasSuffix("/") {
      components.path.append(child)
    } else if components.path.isEmpty {
      components.path = "/" + child
    } else {
      components.path.append("/\(child)")
    }

    return components.url?.absoluteString ?? trimmed
  }

  private static func trimmingLeadingSlash(_ slice: String) -> String {
    var working = slice[...]
    while working.first == "/" { working.removeFirst() }
    return String(working)
  }

  /// Produces progressively shorter HTTPS prefixes usable for probing `/.well-known/...`.
  private static func issuerBaseVariants(for issuer: String) -> [String] {
    guard var components = URLComponents(string: issuer) else { return [] }
    components.query = nil
    components.fragment = nil

    var segments = components.path.split(separator: "/").filter { !$0.isEmpty }.map(String.init)

    guard !segments.isEmpty else {
      guard let url = components.url else { return [] }
      return [stripTrailingSlash(url.absoluteString)]
    }

    var flattened: [String] = []

    while !segments.isEmpty {
      components.path = "/" + segments.joined(separator: "/")

      if let absolute = components.url?.absoluteString {
        flattened.append(stripTrailingSlash(absolute))
      }

      segments.removeLast()
    }

    components.path = ""
    if let rootAbsolute = components.url?.absoluteString {
      flattened.append(stripTrailingSlash(rootAbsolute))
    }

    return flattened.uniqueStable()
  }

  private static func stripTrailingSlash(_ value: String) -> String {
    var sanitized = value
    while sanitized.hasSuffix("/"),
          sanitized.count > "http://x".count
    {
      sanitized.removeLast()
    }
    return sanitized
  }
}

private extension [String] {
  func uniqueStable() -> [String] {
    var buffer: [String] = []

    outer: for item in self {
      for existing in buffer where existing == item {
        continue outer
      }
      buffer.append(item)
    }

    return buffer
  }
}
