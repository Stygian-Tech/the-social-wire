import AsyncHTTPClient
import Foundation
import Hummingbird
import JWTKit
import Logging

/// Caches ATProto issuer discovery (PLC directory + `.well-known` probes) and fetched JWKS
/// documents so bursts of concurrent requests (e.g. bulk unread-mark writes) don't each redo
/// the full multi-hop discovery chain — that fan-out is what trips upstream rate limits (429s)
/// and inflates per-request latency enough to stall connection pools under load.
private actor JWKSVerificationCache {
  private struct Entry<Value: Sendable>: Sendable {
    let value: Value
    let expiresAt: Date
  }

  static let shared = JWKSVerificationCache()

  /// Issuer discovery rarely changes; a longer TTL avoids re-probing PLC + well-known endpoints.
  private let discoveryTTL: TimeInterval = 600
  /// JWKS content can rotate; a shorter TTL keeps rotation windows reasonable while still
  /// collapsing bursts onto a single upstream fetch.
  private let jwksContentTTL: TimeInterval = 300
  /// Discovered JWKS endpoints that fail briefly are negatively cached to collapse request bursts
  /// instead of one failed probe per request, without masking a real fix for very long.
  private let negativeContentTTL: TimeInterval = 60

  private var discoveryCache: [String: Entry<[OAuthAccessTokenVerifier.JwksTarget]>] = [:]
  private var contentCache: [String: Entry<String>] = [:]
  private var negativeContentCache: [String: Date] = [:]

  func cachedTargets(forKey key: String) -> [OAuthAccessTokenVerifier.JwksTarget]? {
    guard let entry = discoveryCache[key], entry.expiresAt > Date() else { return nil }
    return entry.value
  }

  func storeTargets(_ targets: [OAuthAccessTokenVerifier.JwksTarget], forKey key: String) {
    discoveryCache[key] = Entry(value: targets, expiresAt: Date().addingTimeInterval(discoveryTTL))
  }

  func cachedContent(forURL url: String) -> String? {
    guard let entry = contentCache[url], entry.expiresAt > Date() else { return nil }
    return entry.value
  }

  func storeContent(_ json: String, forURL url: String) {
    contentCache[url] = Entry(value: json, expiresAt: Date().addingTimeInterval(jwksContentTTL))
    negativeContentCache[url] = nil
  }

  func recentlyFailed(forURL url: String) -> Bool {
    guard let expiresAt = negativeContentCache[url] else { return false }
    return expiresAt > Date()
  }

  func storeFailure(forURL url: String) {
    negativeContentCache[url] = Date().addingTimeInterval(negativeContentTTL)
  }

  func invalidateContent(forURL url: String) {
    contentCache[url] = nil
  }
}

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
    case issuerSubjectMismatch
    case unsafeRemoteURL
    case jwksFetch(Int?)
    case jwksMissing
    case jwksEmpty(String)
    case plcFetch(Int?)
    case noJwksCandidates
    case signatureRejected
  }

  static func permitsActivePDSFallback(error: Error, supplementalJwksJSON: String?) -> Bool {
    if let supplementalJwksJSON, jwksKeyCount(in: supplementalJwksJSON) > 0 {
      return false
    }
    guard let error = error as? VerifyError else { return false }
    switch error {
    case .jwksEmpty, .jwksMissing, .noJwksCandidates:
      return true
    default:
      return false
    }
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
    guard
      issuerClaim.hasPrefix("http://") || issuerClaim.hasPrefix("https://") || issuerClaim.hasPrefix("did:")
    else {
      throw VerifyError.unsupportedIssuerForm
    }

    var probeError: Error = VerifyError.signatureRejected
    let supplementalTargets = supplementalJwksTargets(from: supplementalJwksJSON)

    for target in supplementalTargets {
      guard case .inline(let json, let source) = target else { continue }
      if let verified = try await verifyAgainstJWKSJSON(
        accessTokenJWT: accessTokenJWT,
        jwksJSON: json,
        source: source,
        logger: logger,
        probeError: &probeError
      ) {
        return verified
      }
    }

    let discoveryKey = "\(issuerClaim)#\(payload.sub.value)"
    let discoveredTargets: [JwksTarget]
    if let cached = await JWKSVerificationCache.shared.cachedTargets(forKey: discoveryKey) {
      discoveredTargets = cached
    } else {
      let baseCandidates = try await issuerBases(
        issuerClaim: issuerClaim,
        subjectDid: payload.sub.value,
        plcURL: plcURL,
        httpClient: httpClient
      )
      guard !baseCandidates.isEmpty else { throw VerifyError.unsupportedIssuerForm }

      let collected = try await collectJwksURLs(
        httpClient: httpClient,
        issuerBases: baseCandidates,
        expectedIssuer: issuerClaim
      )
      if !collected.isEmpty {
        await JWKSVerificationCache.shared.storeTargets(collected, forKey: discoveryKey)
      }
      discoveredTargets = collected
    }

    let jwksTargets = discoveredTargets
    guard !jwksTargets.isEmpty else {
      if supplementalTargets.isEmpty {
        throw VerifyError.noJwksCandidates
      }
      throw probeError
    }

    logger.debug(
      "JWKS probing order",
      metadata: [
        "issuer": .string(issuerClaim),
        "jwks": .string(jwksTargets.map(\.logLabel).joined(separator: " | ")),
      ]
    )

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

  fileprivate enum JwksTarget: Sendable {
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
    guard isAllowedRemoteURL(url) else {
      probeError = VerifyError.unsafeRemoteURL
      return nil
    }

    if let cachedJSON = await JWKSVerificationCache.shared.cachedContent(forURL: url) {
      if let verified = try await verifyAgainstJWKSJSON(
        accessTokenJWT: accessTokenJWT,
        jwksJSON: cachedJSON,
        source: url,
        logger: logger,
        probeError: &probeError
      ) {
        return verified
      }
      // Cached keys may be stale (rotation) — fall through and fetch a fresh copy below.
      await JWKSVerificationCache.shared.invalidateContent(forURL: url)
    }

    if await JWKSVerificationCache.shared.recentlyFailed(forURL: url) {
      probeError = VerifyError.jwksFetch(nil)
      return nil
    }

    var probeRequest = HTTPClientRequest(url: url)
    probeRequest.headers.add(name: "Accept", value: "application/json")

    let jwksResponse = try await httpClient.execute(probeRequest, timeout: .seconds(10))
    guard jwksResponse.status == .ok else {
      probeError = VerifyError.jwksFetch(Int(jwksResponse.status.code))
      await JWKSVerificationCache.shared.storeFailure(forURL: url)
      return nil
    }

    let jwksBlob = try await jwksResponse.body.collect(upTo: 512 * 1024)
    let decodedJWKSString = String(buffer: jwksBlob)
    guard !decodedJWKSString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      probeError = VerifyError.jwksMissing
      return nil
    }

    await JWKSVerificationCache.shared.storeContent(decodedJWKSString, forURL: url)

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
    guard subjectDid.hasPrefix("did:") else { throw VerifyError.issuerSubjectMismatch }
    guard let subjectAuthorities = try await issuerBasesFromDid(
      did: subjectDid,
      plcURL: plcURL,
      httpClient: httpClient
    ) else {
      throw VerifyError.issuerSubjectMismatch
    }
    return try trustedIssuerBases(
      issuerClaim: issuerClaim,
      subjectAuthorities: subjectAuthorities
    )
  }

  static func trustedIssuerBases(
    issuerClaim: String,
    subjectAuthorities: [String]
  ) throws -> [String] {
    guard let normalizedIssuer = normalizedRemoteBase(issuerClaim) else {
      throw VerifyError.unsupportedIssuerForm
    }
    let trusted = subjectAuthorities.compactMap(normalizedRemoteBase)
    guard trusted.contains(normalizedIssuer) else {
      throw VerifyError.issuerSubjectMismatch
    }
    return [normalizedIssuer]
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
    issuerBases: [String],
    expectedIssuer: String
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
          let decoded = try? JSONSerialization.jsonObject(with: Data(buffer: blob)) as? [String: Any],
          let metadataIssuer = decoded["issuer"] as? String,
          normalizedRemoteBase(metadataIssuer) == normalizedRemoteBase(expectedIssuer)
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
          guard isAllowedRemoteURL(normalizedJWKSURI, sameOriginAs: expectedIssuer) else {
            continue
          }
          accumulator.append(.remote(normalizedJWKSURI))
          continue outer
        }
      }
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

    if let rawPdsEndpoint = ATProtoPdsResolution.parsePdsEndpointFromPlcDoc(plcDocument),
      let resolvedPdsEndpoint = normalizedRemoteBase(rawPdsEndpoint)
    {
      bases.append(resolvedPdsEndpoint)
      if let authServers = try await authorizationServersFromProtectedResource(
        pdsBase: resolvedPdsEndpoint,
        httpClient: httpClient
      ) {
        for server in authServers {
          if let normalized = normalizedRemoteBase(server) { bases.append(normalized) }
        }
      }
    }

    if let services = plcDocument["service"] as? [[String: Any]] {
      for service in services {
        guard let endpoint = service["serviceEndpoint"] as? String else { continue }
        let cleaned = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = normalizedRemoteBase(cleaned) else { continue }

        let lexicalType = ((service["type"] as? String) ?? "").lowercased()

        guard
          lexicalType.contains("oauth") || lexicalType.contains("openid") || lexicalType.contains(
            "authserver"
          )
        else {
          continue
        }
        bases.append(normalized)
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

    let cleaned = servers.compactMap(normalizedRemoteBase)
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

  static func isAllowedRemoteURL(_ raw: String, sameOriginAs trustedOrigin: String? = nil) -> Bool {
    guard let normalized = normalizedRemoteBase(raw),
      let candidate = URLComponents(string: normalized)
    else { return false }
    guard let trustedOrigin else { return true }
    guard let trusted = normalizedRemoteBase(trustedOrigin).flatMap(URLComponents.init(string:))
    else { return false }
    return candidate.scheme == trusted.scheme
      && candidate.host == trusted.host
      && effectivePort(candidate) == effectivePort(trusted)
  }

  static func normalizedPublicRemoteBase(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
      components.scheme?.lowercased() == "https",
      let rawHost = components.host?.lowercased(),
      components.user == nil,
      components.password == nil,
      components.fragment == nil
    else { return nil }

    let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
    guard isPublicHostname(host) else { return nil }
    components.scheme = "https"
    components.host = host
    components.query = nil
    if components.path == "/" { components.path = "" }
    while components.path.count > 1, components.path.hasSuffix("/") {
      components.path.removeLast()
    }
    return components.url?.absoluteString
  }

  private static func normalizedRemoteBase(_ raw: String) -> String? {
    normalizedPublicRemoteBase(raw)
  }

  private static func effectivePort(_ components: URLComponents) -> Int {
    components.port ?? 443
  }

  private static func isPublicHostname(_ host: String) -> Bool {
    guard host.contains("."), host.count <= 253, !isIPLiteral(host) else { return false }
    let blockedExact = ["localhost", "example.com", "example.net", "example.org"]
    guard !blockedExact.contains(host) else { return false }
    let blockedSuffixes = [
      ".alt", ".arpa", ".example", ".home.arpa", ".internal", ".invalid", ".local",
      ".localdomain", ".localhost", ".onion", ".test",
    ]
    guard !blockedSuffixes.contains(where: host.hasSuffix) else { return false }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    return labels.count >= 2 && labels.allSatisfy { label in
      !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
        && label.utf8.allSatisfy {
          ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) || $0 == 45
        }
    }
  }

  private static func isIPLiteral(_ host: String) -> Bool {
    if host.contains(":") { return true }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy { part in
      !part.isEmpty && part.allSatisfy(\.isNumber) && UInt8(part) != nil
    }
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
