import AsyncHTTPClient
import Foundation
import Hummingbird
import JWTKit
import Logging

/// Verifies ATProto OAuth access JWTs (`issuer` metadata → JWKS) using JWTKit's `JWTKeyCollection`.
public enum OAuthAccessTokenVerifier {
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
    case jwksEmpty(String)
    case plcFetch(Int?)
    case noJwksCandidates
    case signatureRejected
  }

  /// Cryptographically verifies the access JWT, returning DID + **`cnf.jkt`** plus optional **`client_id`/`azp`/`aud`** claims.
  static func verify(
    accessTokenJWT: String,
    httpClient: HTTPClient,
    plcURL: String,
    logger: Logger,
    supplementalJwksJSON: String? = nil
  )
    async throws -> VerifiedAccessToken
  {
    let unverifiedColl = JWTKeyCollection()
    let payload: AccessClaims = try await unverifiedColl.unverified(accessTokenJWT, as: AccessClaims.self)

    guard let issuerClaim = payload.iss?.value, !issuerClaim.isEmpty else {
      throw VerifyError.missingIssuerClaim
    }

    let baseCandidates = try await issuerBases(
      issuerClaim: issuerClaim,
      subjectDid: payload.sub.value,
      plcURL: plcURL,
      httpClient: httpClient
    )
    guard !baseCandidates.isEmpty else { throw VerifyError.unsupportedIssuerForm }

    let jwksTargets = supplementalJwksTargets(from: supplementalJwksJSON)
      + (try await collectJwksURLs(httpClient: httpClient, issuerBases: baseCandidates))
    guard !jwksTargets.isEmpty else { throw VerifyError.noJwksCandidates }

    logger.debug(
      "JWKS probing order",
      metadata: [
        "issuer": .string(issuerClaim),
        "jwks": .string(jwksTargets.map(\.logLabel).joined(separator: " | ")),
      ]
    )

    var probeError: Error = VerifyError.signatureRejected

    for target in jwksTargets {
      switch target {
      case .remote(let url):
        guard let verified = try await verifyAgainstRemoteJWKS(
          accessTokenJWT: accessTokenJWT,
          url: url,
          httpClient: httpClient,
          logger: logger,
          probeError: &probeError
        ) else {
          continue
        }
        return verified
      case .inline(let json, let source):
        guard let verified = try await verifyAgainstJWKSJSON(
          accessTokenJWT: accessTokenJWT,
          jwksJSON: json,
          source: source,
          logger: logger,
          probeError: &probeError
        ) else {
          continue
        }
        return verified
      }
    }

    throw probeError
  }

  /// First-party gateway fallback when issuer JWKS omits access-token signing keys.
  /// Validates DPoP binding plus structural JWT claims (`exp`, `sub`, optional `cnf.jkt`) without signature verification.
  static func verifyDpopBoundStructural(
    accessTokenJWT: String,
    request: Request,
    dpopProof: String,
    logger: Logger
  ) async throws -> VerifiedAccessToken {
    let unverifiedColl = JWTKeyCollection()
    let payload: AccessClaims = try await unverifiedColl.unverified(accessTokenJWT, as: AccessClaims.self)

    try payload.exp.verifyNotExpired()

    let subject = payload.sub.value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard subject.hasPrefix("did:") else {
      throw HTTPError(.unauthorized, message: "`sub` must be an ATProto DID")
    }

    let rawJkt = payload.cnf?.jkt?.trimmingCharacters(in: .whitespacesAndNewlines)
    let cnfJkt = (rawJkt?.isEmpty == false) ? rawJkt : nil
    let extra = extractRegisteredClientSignals(fromJWT: accessTokenJWT)

    do {
      try DPoPProofVerifier.verify(
        proofJWT: dpopProof,
        request: request,
        accessTokenJWT: accessTokenJWT,
        accessTokenCnFJkt: cnfJkt
      )
    } catch {
      logger.warning(
        "DPoP verification failed during structural fallback",
        metadata: ["error": .string("\(error)")]
      )
      throw error
    }

    logger.info(
      "Accepted DPoP-bound structural access token fallback",
      metadata: [
        "did": .string(subject),
        "issuer": .string(payload.iss?.value ?? "<missing>"),
      ]
    )

    return VerifiedAccessToken(
      did: subject,
      cnfJkt: cnfJkt,
      clientIdClaim: extra.clientId,
      azpClaim: extra.azp,
      audiences: extra.audiences
    )
  }

  private enum JwksTarget: Sendable {
    case remote(String)
    case inline(String, source: String)

    var logLabel: String {
      switch self {
      case .remote(let url): url
      case .inline(_, let source): source
      }
    }
  }

  private static func supplementalJwksTargets(from raw: String?) -> [JwksTarget] {
    guard
      let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty,
      jwksKeyCount(in: trimmed) > 0
    else {
      return []
    }
    return [.inline(trimmed, source: "env:OAUTH_ACCESS_TOKEN_SUPPLEMENTAL_JWKS_JSON")]
  }

  private static func verifyAgainstRemoteJWKS(
    accessTokenJWT: String,
    url: String,
    httpClient: HTTPClient,
    logger: Logger,
    probeError: inout Error
  ) async throws -> VerifiedAccessToken? {
    guard URL(string: url) != nil else { return nil }

    var probeRequest = HTTPClientRequest(url: url)
    probeRequest.headers.add(name: "Accept", value: "application/json")

    let jwksResponse = try await httpClient.execute(probeRequest, timeout: .seconds(10))
    guard jwksResponse.status == .ok else {
      probeError = VerifyError.jwksFetch(Int(jwksResponse.status.code))
      return nil
    }

    let jwksBlob = try await jwksResponse.body.collect(upTo: 512 * 1024)
    let decodedJWKSString = String(buffer: jwksBlob)
    guard !decodedJWKSString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      probeError = VerifyError.jwksMissing
      return nil
    }

    return try await verifyAgainstJWKSJSON(
      accessTokenJWT: accessTokenJWT,
      jwksJSON: decodedJWKSString,
      source: url,
      logger: logger,
      probeError: &probeError
    )
  }

  private static func verifyAgainstJWKSJSON(
    accessTokenJWT: String,
    jwksJSON: String,
    source: String,
    logger: Logger,
    probeError: inout Error
  ) async throws -> VerifiedAccessToken? {
    guard jwksKeyCount(in: jwksJSON) > 0 else {
      logger.debug("Skipping empty JWKS", metadata: ["source": .string(source)])
      probeError = VerifyError.jwksEmpty(source)
      return nil
    }

    let signers = JWTKeyCollection()
    do {
      try await signers.add(jwksJSON: jwksJSON)
    } catch {
      logger.debug(
        "JWKS import failed",
        metadata: ["source": .string(source), "error": .string("\(error)")]
      )
      probeError = error
      return nil
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
      logger.debug(
        "JWKS signature verification failed",
        metadata: ["source": .string(source), "error": .string("\(error)")]
      )
      probeError = error
      return nil
    }
  }

  private static func issuerBases(
    issuerClaim: String,
    subjectDid: String,
    plcURL: String,
    httpClient: HTTPClient
  ) async throws -> [String] {
    var bases: [String] = []

    if issuerClaim.hasPrefix("http://") || issuerClaim.hasPrefix("https://") {
      bases.append(contentsOf: issuerBaseVariants(for: issuerClaim))
    } else if issuerClaim.hasPrefix("did:"),
              let didBases = try await issuerBasesFromDid(did: issuerClaim, plcURL: plcURL, httpClient: httpClient) {
      bases.append(contentsOf: didBases)
    }

    if subjectDid.hasPrefix("did:") {
      if let pdsBases = try await issuerBasesFromDid(did: subjectDid, plcURL: plcURL, httpClient: httpClient) {
        bases.append(contentsOf: pdsBases)
      }
    }

    return bases.uniqueStable()
  }

  private static func jwksKeyCount(in json: String) -> Int {
    guard
      let data = json.data(using: .utf8),
      let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let keys = decoded["keys"] as? [Any]
    else {
      return 0
    }
    return keys.count
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
  ) async throws -> [JwksTarget] {
    var accumulator: [JwksTarget] = []

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
          let decoded = try? JSONSerialization.jsonObject(with: Data(buffer: blob)) as? [String: Any]
        else {
          continue
        }

        if
          let inline = decoded["jwks"] as? [String: Any],
          let inlineData = try? JSONSerialization.data(withJSONObject: inline),
          let inlineJSON = String(data: inlineData, encoding: .utf8),
          jwksKeyCount(in: inlineJSON) > 0
        {
          accumulator.append(.inline(inlineJSON, source: "\(sanitizedBase)\(suffix)#jwks"))
        }

        if let jwks = decoded["jwks_uri"] as? String {
          let normalizedJWKSURI = normalizeRelativeJWKSURI(jwks, bases: issuerBases)
          accumulator.append(.remote(normalizedJWKSURI))
          continue outer
        }
      }

      accumulator.append(.remote(sanitizedBase + "/jwt/jwks"))
      accumulator.append(.remote(sanitizedBase + "/oauth/jwks"))
    }

    return dedupeJwksTargets(accumulator)
  }

  private static func dedupeJwksTargets(_ items: [JwksTarget]) -> [JwksTarget] {
    var buffer: [JwksTarget] = []

    outer: for item in items {
      for existing in buffer {
        switch (existing, item) {
        case (.remote(let left), .remote(let right)) where left == right:
          continue outer
        case (.inline(let left, source: let leftSource), .inline(let right, source: let rightSource))
          where left == right && leftSource == rightSource:
          continue outer
        default:
          continue
        }
      }
      buffer.append(item)
    }

    return buffer
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
      if let authServers = try await authorizationServersFromProtectedResource(
        pdsBase: resolvedPdsEndpoint,
        httpClient: httpClient
      ) {
        for server in authServers {
          bases.append(contentsOf: issuerBaseVariants(for: server))
        }
      }
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

  /// ATProto OAuth: `{pds}/.well-known/oauth-protected-resource` → `authorization_servers`.
  private static func authorizationServersFromProtectedResource(
    pdsBase: String,
    httpClient: HTTPClient
  ) async throws -> [String]? {
    let root = stripTrailingSlash(pdsBase)
    guard let probe = URL(string: "\(root)/.well-known/oauth-protected-resource") else { return nil }

    var request = HTTPClientRequest(url: probe.absoluteString)
    request.headers.add(name: "Accept", value: "application/json")

    let response = try await httpClient.execute(request, timeout: .seconds(10))
    guard response.status == .ok else { return nil }

    let blob = try await response.body.collect(upTo: 64 * 1024)
    guard
      let decoded = try? JSONSerialization.jsonObject(with: Data(buffer: blob)) as? [String: Any],
      let servers = decoded["authorization_servers"] as? [String]
    else {
      return nil
    }

    let cleaned = servers
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
    return cleaned.isEmpty ? nil : cleaned.uniqueStable()
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
