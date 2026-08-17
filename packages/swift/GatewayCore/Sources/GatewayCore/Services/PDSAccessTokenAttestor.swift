import AsyncHTTPClient
import Crypto
import Foundation
import Logging
import NIOCore

enum PDSAccessTokenAttestationError: Error, Sendable, Equatable {
  case invalid
  case unavailable
  case overloaded
  case nonceChallenge(String)
}

struct PDSAccessTokenAttestationOutcome: Sendable {
  let token: OAuthAccessTokenVerifier.VerifiedAccessToken
  let responseNonce: String?
  /// Exact authority window shared by fresh and cached attestations.
  let attestationExpiresAt: Date
}

protocol PDSAccessTokenAttesting: Sendable {
  func attest(
    accessTokenJWT: String,
    authorizationValue: String,
    gatewayProof: DPoPProofVerifier.VerifiedProof,
    sessionProof: String?
  ) async throws -> PDSAccessTokenAttestationOutcome
}

private actor PDSResponseBodyCollectionAttempt {
  private enum Outcome: Sendable {
    case body(Data)
    case invalid
    case unavailable
  }

  private var outcome: Outcome?
  private var continuation: CheckedContinuation<Data, any Error>?

  func value() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      if let outcome {
        Self.resume(continuation, with: outcome)
      } else {
        self.continuation = continuation
      }
    }
  }

  func collected(_ body: Data) { finish(with: .body(body)) }
  func failedInvalid() { finish(with: .invalid) }
  func failedUnavailable() { finish(with: .unavailable) }

  private func finish(with newOutcome: Outcome) {
    guard outcome == nil else { return }
    outcome = newOutcome
    guard let continuation else { return }
    self.continuation = nil
    Self.resume(continuation, with: newOutcome)
  }

  private static func resume(
    _ continuation: CheckedContinuation<Data, any Error>,
    with outcome: Outcome
  ) {
    switch outcome {
    case .body(let body):
      continuation.resume(returning: body)
    case .invalid:
      continuation.resume(throwing: PDSAccessTokenAttestationError.invalid)
    case .unavailable:
      continuation.resume(throwing: PDSAccessTokenAttestationError.unavailable)
    }
  }
}

actor PDSAccessTokenAttestor: PDSAccessTokenAttesting {
  private struct CompletedAttestation: Sendable {
    let token: OAuthAccessTokenVerifier.VerifiedAccessToken
    let responseNonce: String?
  }

  struct Candidate: Sendable {
    let issuer: String
    let did: String
    let expiresAt: Date
    let cnfJkt: String
    let token: OAuthAccessTokenVerifier.VerifiedAccessToken
  }

  struct Authority: Sendable {
    let pdsBase: String
    let authorizationServers: [String]
  }

  private struct CacheEntry: Sendable {
    let token: OAuthAccessTokenVerifier.VerifiedAccessToken
    let expiresAt: Date
  }

  typealias AuthorityResolver = @Sendable (Candidate) async throws -> Authority
  typealias SessionProbe = @Sendable (Authority, String, String) async throws -> (did: String, active: Bool?, nonce: String?)

  private let authorityResolver: AuthorityResolver
  private let sessionProbe: SessionProbe
  private let now: @Sendable () -> Date
  private let ttl: TimeInterval
  private let maximumEntries: Int
  private let maximumInFlight: Int
  private let maximumInFlightPerOrigin: Int
  private let overloadReporter: @Sendable (String) -> Void
  private var cache: [String: CacheEntry] = [:]
  private var inFlight: [String: Task<PDSAccessTokenAttestationOutcome, Error>] = [:]
  private var inFlightByOrigin: [String: Int] = [:]

  init(
    httpClient: HTTPClient,
    plcURL: String,
    logger: Logger,
    ttl: TimeInterval = 60
  ) {
    self.authorityResolver = { candidate in
      try await Self.resolveAuthority(
        candidate: candidate,
        httpClient: httpClient,
        plcURL: plcURL
      )
    }
    self.sessionProbe = { authority, authorization, proof in
      try await Self.probeSession(
        authority: authority,
        authorizationValue: authorization,
        proof: proof,
        httpClient: httpClient,
        logger: logger
      )
    }
    self.now = Date.init
    self.ttl = min(max(ttl, 1), 60)
    self.maximumEntries = 10_000
    self.maximumInFlight = 64
    self.maximumInFlightPerOrigin = 8
    self.overloadReporter = { dimension in
      logger.warning(
        "Active PDS attestation admission rejected",
        metadata: ["dimension": .string(dimension)]
      )
    }
  }

  init(
    ttl: TimeInterval = 60,
    maximumEntries: Int = 10_000,
    maximumInFlight: Int = 64,
    maximumInFlightPerOrigin: Int = 8,
    now: @escaping @Sendable () -> Date = Date.init,
    overloadReporter: @escaping @Sendable (String) -> Void = { _ in },
    authorityResolver: @escaping AuthorityResolver,
    sessionProbe: @escaping SessionProbe
  ) {
    self.authorityResolver = authorityResolver
    self.sessionProbe = sessionProbe
    self.now = now
    self.ttl = min(max(ttl, 1), 60)
    self.maximumEntries = max(maximumEntries, 1)
    self.maximumInFlight = max(maximumInFlight, 1)
    self.maximumInFlightPerOrigin = max(maximumInFlightPerOrigin, 1)
    self.overloadReporter = overloadReporter
  }

  func attest(
    accessTokenJWT: String,
    authorizationValue: String,
    gatewayProof: DPoPProofVerifier.VerifiedProof,
    sessionProof: String?
  ) async throws -> PDSAccessTokenAttestationOutcome {
    let instant = now()
    let candidate = try Self.decodeCandidate(accessTokenJWT, now: instant)
    guard candidate.cnfJkt == gatewayProof.jwkThumbprint else {
      throw PDSAccessTokenAttestationError.invalid
    }

    prune(now: instant)
    let cacheKey = Self.cacheKey(token: accessTokenJWT, thumbprint: gatewayProof.jwkThumbprint)
    if let cached = cache[cacheKey], cached.expiresAt > instant {
      return PDSAccessTokenAttestationOutcome(
        token: cached.token,
        responseNonce: nil,
        attestationExpiresAt: cached.expiresAt
      )
    }
    if let existing = inFlight[cacheKey] {
      return try await existing.value
    }
    guard let sessionProof else { throw PDSAccessTokenAttestationError.invalid }
    guard inFlight.count < maximumInFlight else {
      overloadReporter("global")
      throw PDSAccessTokenAttestationError.overloaded
    }

    let authorityResolver = self.authorityResolver
    let expiration = min(candidate.expiresAt, instant.addingTimeInterval(ttl))
    let task = Task<PDSAccessTokenAttestationOutcome, Error> {
      let authority = try await authorityResolver(candidate)
      let outcome = try await self.completeAttestation(
        candidate: candidate,
        authority: authority,
        accessTokenJWT: accessTokenJWT,
        authorizationValue: authorizationValue,
        gatewayProof: gatewayProof,
        sessionProof: sessionProof
      )
      return PDSAccessTokenAttestationOutcome(
        token: outcome.token,
        responseNonce: outcome.responseNonce,
        attestationExpiresAt: expiration
      )
    }
    inFlight[cacheKey] = task
    do {
      let outcome = try await task.value
      inFlight[cacheKey] = nil
      if cache.count >= maximumEntries,
        let oldest = cache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key
      {
        cache.removeValue(forKey: oldest)
      }
      cache[cacheKey] = CacheEntry(token: outcome.token, expiresAt: expiration)
      return outcome
    } catch {
      inFlight[cacheKey] = nil
      throw error
    }
  }

  private func prune(now: Date) {
    cache = cache.filter { $0.value.expiresAt > now }
  }

  private func completeAttestation(
    candidate: Candidate,
    authority: Authority,
    accessTokenJWT: String,
    authorizationValue: String,
    gatewayProof: DPoPProofVerifier.VerifiedProof,
    sessionProof: String
  ) async throws -> CompletedAttestation {
    let normalizedIssuer = OAuthAccessTokenVerifier.normalizedPublicRemoteBase(candidate.issuer)
    let trustedIssuers = authority.authorizationServers.compactMap(
      OAuthAccessTokenVerifier.normalizedPublicRemoteBase
    )
    guard let normalizedIssuer, trustedIssuers.contains(normalizedIssuer) else {
      throw PDSAccessTokenAttestationError.invalid
    }

    let origin = authority.pdsBase
    let activeForOrigin = inFlightByOrigin[origin, default: 0]
    guard activeForOrigin < maximumInFlightPerOrigin else {
      overloadReporter("origin")
      throw PDSAccessTokenAttestationError.overloaded
    }
    inFlightByOrigin[origin] = activeForOrigin + 1
    defer {
      let remaining = inFlightByOrigin[origin, default: 1] - 1
      if remaining == 0 {
        inFlightByOrigin[origin] = nil
      } else {
        inFlightByOrigin[origin] = remaining
      }
    }

    let sessionURL = "\(authority.pdsBase)/xrpc/com.atproto.server.getSession"
    let verifiedSessionProof: DPoPProofVerifier.VerifiedProof
    do {
      verifiedSessionProof = try DPoPProofVerifier.verify(
        proofJWT: sessionProof,
        uppercasedHTTPMethod: "GET",
        expectedHtuURL: sessionURL,
        accessTokenJWT: accessTokenJWT,
        accessTokenCnFJkt: candidate.cnfJkt
      )
    } catch {
      throw PDSAccessTokenAttestationError.invalid
    }
    guard verifiedSessionProof.jwkThumbprint == gatewayProof.jwkThumbprint else {
      throw PDSAccessTokenAttestationError.invalid
    }

    let session = try await sessionProbe(authority, authorizationValue, sessionProof)
    guard session.did == candidate.did, session.active != false else {
      throw PDSAccessTokenAttestationError.invalid
    }
    return CompletedAttestation(
      token: candidate.token,
      responseNonce: session.nonce
    )
  }

  static func decodeCandidate(_ jwt: String, now: Date = Date()) throws -> Candidate {
    guard !jwt.isEmpty, jwt.utf8.count <= 32 * 1024 else {
      throw PDSAccessTokenAttestationError.invalid
    }
    let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3,
      let payload = try JSONSerialization.jsonObject(with: Base64URL.decode(String(segments[1])))
        as? [String: Any],
      let issuer = nonempty(payload["iss"] as? String),
      let did = nonempty(payload["sub"] as? String), did.hasPrefix("did:plc:"),
      let cnf = payload["cnf"] as? [String: Any],
      let cnfJkt = nonempty(cnf["jkt"] as? String),
      let expirationSeconds = numericTimestamp(payload["exp"])
    else {
      throw PDSAccessTokenAttestationError.invalid
    }
    let expiresAt = Date(timeIntervalSince1970: expirationSeconds)
    guard expiresAt > now, OAuthAccessTokenVerifier.normalizedPublicRemoteBase(issuer) != nil else {
      throw PDSAccessTokenAttestationError.invalid
    }

    let clientId = nonempty(payload["client_id"] as? String)
      ?? nonempty(payload["clientId"] as? String)
    let azp = nonempty(payload["azp"] as? String)
    let audiences: [String]
    if let audience = payload["aud"] as? String {
      audiences = [audience]
    } else if let values = payload["aud"] as? [String] {
      audiences = values
    } else {
      audiences = []
    }
    let token = OAuthAccessTokenVerifier.VerifiedAccessToken(
      did: did,
      cnfJkt: cnfJkt,
      clientIdClaim: clientId,
      azpClaim: azp,
      audiences: audiences
    )
    return Candidate(issuer: issuer, did: did, expiresAt: expiresAt, cnfJkt: cnfJkt, token: token)
  }

  private static func resolveAuthority(
    candidate: Candidate,
    httpClient: HTTPClient,
    plcURL: String
  ) async throws -> Authority {
    let root = ATProtoPdsResolution.normalizePdsBase(plcURL)
    let encoded = candidate.did.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
      ?? candidate.did
    var plcRequest = HTTPClientRequest(url: "\(root)/\(encoded)")
    plcRequest.headers.add(name: "Accept", value: "application/json")
    let plcResponse: HTTPClientResponse
    do {
      plcResponse = try await httpClient.execute(plcRequest, timeout: .seconds(10))
    } catch {
      throw PDSAccessTokenAttestationError.unavailable
    }
    guard plcResponse.status == .ok else {
      if plcResponse.status.code == 429 || plcResponse.status.code >= 500 {
        throw PDSAccessTokenAttestationError.unavailable
      }
      throw PDSAccessTokenAttestationError.invalid
    }
    let plcBody: ByteBuffer
    do {
      plcBody = try await plcResponse.body.collect(upTo: 256 * 1024)
    } catch is NIOTooManyBytesError {
      throw PDSAccessTokenAttestationError.invalid
    } catch {
      throw PDSAccessTokenAttestationError.unavailable
    }
    guard let document = try? JSONSerialization.jsonObject(with: Data(buffer: plcBody)) as? [String: Any],
      let rawPDS = ATProtoPdsResolution.parsePdsEndpointFromPlcDoc(document),
      let pdsBase = OAuthAccessTokenVerifier.normalizedPublicRemoteBase(rawPDS)
    else {
      throw PDSAccessTokenAttestationError.invalid
    }
    var metadataRequest = HTTPClientRequest(
      url: "\(pdsBase)/.well-known/oauth-protected-resource")
    metadataRequest.headers.add(name: "Accept", value: "application/json")
    let metadataResponse = try await executePinnedPDSRequest(
      metadataRequest,
      pdsBase: pdsBase,
      httpClient: httpClient,
      maximumBodyBytes: 64 * 1024
    )
    guard metadataResponse.statusCode == 200 else {
      if metadataResponse.statusCode == 429 || metadataResponse.statusCode >= 500 {
        throw PDSAccessTokenAttestationError.unavailable
      }
      throw PDSAccessTokenAttestationError.invalid
    }
    guard let metadata = try? JSONSerialization.jsonObject(with: metadataResponse.body)
      as? [String: Any],
      let rawServers = metadata["authorization_servers"] as? [String]
    else {
      throw PDSAccessTokenAttestationError.invalid
    }
    let servers = rawServers.compactMap(OAuthAccessTokenVerifier.normalizedPublicRemoteBase)
    guard !servers.isEmpty else { throw PDSAccessTokenAttestationError.invalid }
    return Authority(pdsBase: pdsBase, authorizationServers: servers)
  }

  private static func probeSession(
    authority: Authority,
    authorizationValue: String,
    proof: String,
    httpClient: HTTPClient,
    logger: Logger
  ) async throws -> (did: String, active: Bool?, nonce: String?) {
    var request = HTTPClientRequest(
      url: "\(authority.pdsBase)/xrpc/com.atproto.server.getSession")
    request.method = .GET
    request.headers.add(name: "Accept", value: "application/json")
    request.headers.add(name: "Authorization", value: authorizationValue)
    request.headers.add(name: "DPoP", value: proof)

    let response = try await executePinnedPDSRequest(
      request,
      pdsBase: authority.pdsBase,
      httpClient: httpClient,
      maximumBodyBytes: 64 * 1024
    )
    if response.statusCode != 200 {
      return try interpretSessionResponse(
        statusCode: response.statusCode,
        nonce: response.nonce,
        body: Data()
      )
    }
    do {
      return try interpretSessionResponse(
        statusCode: response.statusCode,
        nonce: response.nonce,
        body: response.body
      )
    } catch PDSAccessTokenAttestationError.invalid {
      logger.warning("PDS getSession returned an invalid bounded response")
      throw PDSAccessTokenAttestationError.invalid
    }
  }

  private static func executePinnedPDSRequest(
    _ request: HTTPClientRequest,
    pdsBase: String,
    httpClient: HTTPClient,
    maximumBodyBytes: Int
  ) async throws -> (statusCode: Int, nonce: String?, body: Data) {
    guard let host = URLComponents(string: pdsBase)?.host else {
      throw PDSAccessTokenAttestationError.invalid
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    let address = try await PublicDNSAddressValidator.validatedAddress(
      for: pdsBase,
      deadline: deadline
    )
    guard let requestTimeout = remainingTimeout(until: deadline, clock: clock) else {
      throw PDSAccessTokenAttestationError.unavailable
    }
    var configuration = HTTPClient.Configuration()
    // Pin the request to the address that was just classified. TLS SNI and certificate checks
    // continue to use `host`, while a second DNS lookup cannot redirect the socket internally.
    configuration.dnsOverride = [host: address]
    configuration.redirectConfiguration = .disallow
    let pinnedClient = HTTPClient(
      eventLoopGroup: httpClient.eventLoopGroup,
      configuration: configuration
    )
    do {
      let response: HTTPClientResponse
      do {
        response = try await pinnedClient.execute(request, timeout: requestTimeout)
      } catch {
        throw PDSAccessTokenAttestationError.unavailable
      }
      let result = try await consumePinnedPDSResponse(
        response,
        deadline: deadline,
        maximumBodyBytes: maximumBodyBytes
      )
      try? await pinnedClient.shutdown()
      return result
    } catch {
      try? await pinnedClient.shutdown()
      throw error
    }
  }

  static func consumePinnedPDSResponse(
    _ response: HTTPClientResponse,
    deadline: ContinuousClock.Instant,
    maximumBodyBytes: Int
  ) async throws -> (statusCode: Int, nonce: String?, body: Data) {
    let responseMetadata = (
      statusCode: Int(response.status.code),
      nonce: response.headers.first(name: "DPoP-Nonce")
    )
    guard response.status == .ok else {
      return (responseMetadata.statusCode, responseMetadata.nonce, Data())
    }

    let attempt = PDSResponseBodyCollectionAttempt()
    let collectionTask = Task {
      do {
        let body = Data(buffer: try await response.body.collect(upTo: maximumBodyBytes))
        await attempt.collected(body)
      } catch is NIOTooManyBytesError {
        await attempt.failedInvalid()
      } catch {
        await attempt.failedUnavailable()
      }
    }
    let timeoutTask = Task {
      do {
        try await Task.sleep(until: deadline, clock: .continuous)
        collectionTask.cancel()
        await attempt.failedUnavailable()
      } catch {
        // Body collection completed first and cancelled this deadline task.
      }
    }
    defer { timeoutTask.cancel() }

    let body = try await withTaskCancellationHandler {
      try await attempt.value()
    } onCancel: {
      collectionTask.cancel()
      Task { await attempt.failedUnavailable() }
    }
    return (responseMetadata.statusCode, responseMetadata.nonce, body)
  }

  private static func remainingTimeout(
    until deadline: ContinuousClock.Instant,
    clock: ContinuousClock
  ) -> TimeAmount? {
    let remaining = clock.now.duration(to: deadline)
    guard remaining > .zero else { return nil }
    let components = remaining.components
    let nanoseconds = components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    guard nanoseconds > 0 else { return nil }
    return .nanoseconds(nanoseconds)
  }

  static func interpretSessionResponse(
    statusCode: Int,
    nonce: String?,
    body: Data
  ) throws -> (did: String, active: Bool?, nonce: String?) {
    let safeNonce = boundedNonce(nonce)
    if [400, 401].contains(statusCode), let safeNonce {
      throw PDSAccessTokenAttestationError.nonceChallenge(safeNonce)
    }
    guard statusCode == 200 else {
      if statusCode == 429 || statusCode >= 500 {
        throw PDSAccessTokenAttestationError.unavailable
      }
      throw PDSAccessTokenAttestationError.invalid
    }
    guard body.count <= 64 * 1024,
      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let did = nonempty(json["did"] as? String)
    else {
      throw PDSAccessTokenAttestationError.invalid
    }
    return (did, json["active"] as? Bool, safeNonce)
  }

  private static func cacheKey(token: String, thumbprint: String) -> String {
    let material = Data("\(token):\(thumbprint)".utf8)
    return Base64URL.encodeNoPadding(digest: SHA256.hash(data: material))
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private static func numericTimestamp(_ value: Any?) -> TimeInterval? {
    if let value = value as? Double { return value }
    if let value = value as? Int { return TimeInterval(value) }
    if let value = value as? NSNumber { return value.doubleValue }
    return nil
  }

  private static func boundedNonce(_ raw: String?) -> String? {
    guard let value = nonempty(raw), value.utf8.count <= 1_024 else { return nil }
    return value
  }
}
