import AsyncHTTPClient
import Crypto
import Foundation
import NIOCore
import Testing

@testable import GatewayCore

@Suite("PDS access token attestation")
struct PDSAccessTokenAttestorTests {
  private actor ProbeCounter {
    private(set) var count = 0
    func increment() { count += 1 }
  }

  private actor AsyncGate {
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
      arrivals += 1
      await withCheckedContinuation { waiters.append($0) }
    }

    func waitForArrivalCount(_ expected: Int) async {
      while arrivals < expected { await Task.yield() }
    }

    func open() {
      let pending = waiters
      waiters.removeAll()
      pending.forEach { $0.resume() }
    }
  }

  @Test("active PDS acceptance is cached by token and proof key")
  func cachesPositiveAttestation() async throws {
    let fixture = try Fixture()
    let probes = ProbeCounter()
    let attestor = PDSAccessTokenAttestor(
      authorityResolver: { _ in fixture.authority },
      sessionProbe: { _, authorization, _ in
        await probes.increment()
        #expect(authorization == "DPoP \(fixture.accessToken)")
        return (fixture.did, true, "next-pds-nonce")
      }
    )

    let first = try await attestor.attest(
      accessTokenJWT: fixture.accessToken,
      authorizationValue: "DPoP \(fixture.accessToken)",
      gatewayProof: fixture.gatewayProof,
      sessionProof: fixture.sessionProof
    )
    let cached = try await attestor.attest(
      accessTokenJWT: fixture.accessToken,
      authorizationValue: "DPoP \(fixture.accessToken)",
      gatewayProof: fixture.gatewayProof,
      sessionProof: nil
    )

    #expect(first.token.did == fixture.did)
    #expect(first.responseNonce == "next-pds-nonce")
    #expect(cached.token.did == fixture.did)
    #expect(cached.responseNonce == nil)
    #expect(first.attestationExpiresAt == cached.attestationExpiresAt)
    #expect(await probes.count == 1)
  }

  @Test("issuer must be authorized by the resolved PDS protected resource")
  func rejectsIssuerMismatch() async throws {
    let fixture = try Fixture()
    let attestor = PDSAccessTokenAttestor(
      authorityResolver: { _ in
        .init(pdsBase: fixture.pdsBase, authorizationServers: ["https://other-auth.public.social"])
      },
      sessionProbe: { _, _, _ in
        Issue.record("getSession must not run for an issuer mismatch")
        return (fixture.did, true, nil)
      }
    )

    await #expect(throws: PDSAccessTokenAttestationError.invalid) {
      _ = try await attestor.attest(
        accessTokenJWT: fixture.accessToken,
        authorizationValue: "DPoP \(fixture.accessToken)",
        gatewayProof: fixture.gatewayProof,
        sessionProof: fixture.sessionProof
      )
    }
  }

  @Test("gateway, token, and session proof keys must match")
  func rejectsMismatchedProofKey() async throws {
    let fixture = try Fixture()
    let wrongGateway = DPoPProofVerifier.VerifiedProof(
      jwkThumbprint: "wrong-thumbprint",
      jti: "gateway-jti"
    )
    let attestor = PDSAccessTokenAttestor(
      authorityResolver: { _ in fixture.authority },
      sessionProbe: { _, _, _ in
        Issue.record("getSession must not run for a mismatched gateway key")
        return (fixture.did, true, nil)
      }
    )

    await #expect(throws: PDSAccessTokenAttestationError.invalid) {
      _ = try await attestor.attest(
        accessTokenJWT: fixture.accessToken,
        authorizationValue: "DPoP \(fixture.accessToken)",
        gatewayProof: wrongGateway,
        sessionProof: fixture.sessionProof
      )
    }
  }

  @Test("JWK thumbprints are compared case-sensitively")
  func rejectsCaseChangedThumbprint() async throws {
    let fixture = try Fixture()
    var changedCharacters = Array(fixture.thumbprint)
    let alphabeticIndex = try #require(changedCharacters.firstIndex { $0.isLetter })
    let letter = changedCharacters[alphabeticIndex]
    changedCharacters[alphabeticIndex] = Character(
      letter.isUppercase ? letter.lowercased() : letter.uppercased()
    )
    let changed = String(changedCharacters)
    let attestor = PDSAccessTokenAttestor(
      authorityResolver: { _ in fixture.authority },
      sessionProbe: { _, _, _ in
        Issue.record("getSession must not run for a case-changed thumbprint")
        return (fixture.did, true, nil)
      }
    )
    await #expect(throws: PDSAccessTokenAttestationError.invalid) {
      _ = try await attestor.attest(
        accessTokenJWT: fixture.accessToken,
        authorizationValue: "DPoP \(fixture.accessToken)",
        gatewayProof: .init(jwkThumbprint: changed, jti: "gateway-jti"),
        sessionProof: fixture.sessionProof
      )
    }
  }

  @Test("getSession DID and active state fail closed")
  func rejectsWrongOrInactiveSession() async throws {
    let fixture = try Fixture()
    for response in [("did:plc:other", true), (fixture.did, false)] {
      let attestor = PDSAccessTokenAttestor(
        authorityResolver: { _ in fixture.authority },
        sessionProbe: { _, _, _ in (response.0, response.1, nil) }
      )
      await #expect(throws: PDSAccessTokenAttestationError.invalid) {
        _ = try await attestor.attest(
          accessTokenJWT: fixture.accessToken,
          authorizationValue: "DPoP \(fixture.accessToken)",
          gatewayProof: fixture.gatewayProof,
          sessionProof: fixture.sessionProof
        )
      }
    }
  }

  @Test("nonce challenges and availability failures are never cached")
  func doesNotCacheFailures() async throws {
    let fixture = try Fixture()
    let probes = ProbeCounter()
    let attestor = PDSAccessTokenAttestor(
      authorityResolver: { _ in fixture.authority },
      sessionProbe: { _, _, _ in
        await probes.increment()
        throw PDSAccessTokenAttestationError.nonceChallenge("fresh-nonce")
      }
    )

    for _ in 0..<2 {
      await #expect(throws: PDSAccessTokenAttestationError.nonceChallenge("fresh-nonce")) {
        _ = try await attestor.attest(
          accessTokenJWT: fixture.accessToken,
          authorizationValue: "DPoP \(fixture.accessToken)",
          gatewayProof: fixture.gatewayProof,
          sessionProof: fixture.sessionProof
        )
      }
    }
    #expect(await probes.count == 2)
  }

  @Test("global attestation admission fails closed before launching unbounded work")
  func globalAdmissionBound() async throws {
    let fixture = try Fixture()
    let gate = AsyncGate()
    let attestor = PDSAccessTokenAttestor(
      maximumInFlight: 1,
      authorityResolver: { _ in
        await gate.arriveAndWait()
        return fixture.authority
      },
      sessionProbe: { _, _, _ in (fixture.did, true, nil) }
    )

    let first = Task {
      try await attestor.attest(
        accessTokenJWT: fixture.accessToken,
        authorizationValue: "DPoP \(fixture.accessToken)",
        gatewayProof: fixture.gatewayProof,
        sessionProof: fixture.sessionProof
      )
    }
    await gate.waitForArrivalCount(1)

    let secondToken = fixture.token(
      issuer: fixture.issuer,
      did: fixture.did,
      expiresAt: Date().addingTimeInterval(601)
    )
    await #expect(throws: PDSAccessTokenAttestationError.overloaded) {
      _ = try await attestor.attest(
        accessTokenJWT: secondToken,
        authorizationValue: "DPoP \(secondToken)",
        gatewayProof: fixture.gatewayProof,
        sessionProof: fixture.sessionProof
      )
    }
    await gate.open()
    _ = try await first.value
  }

  @Test("per-origin attestation admission isolates a busy PDS")
  func perOriginAdmissionBound() async throws {
    let fixture = try Fixture()
    let gate = AsyncGate()
    let attestor = PDSAccessTokenAttestor(
      maximumInFlight: 4,
      maximumInFlightPerOrigin: 1,
      authorityResolver: { _ in fixture.authority },
      sessionProbe: { _, _, _ in
        await gate.arriveAndWait()
        return (fixture.did, true, nil)
      }
    )

    let first = Task {
      try await attestor.attest(
        accessTokenJWT: fixture.accessToken,
        authorizationValue: "DPoP \(fixture.accessToken)",
        gatewayProof: fixture.gatewayProof,
        sessionProof: fixture.sessionProof
      )
    }
    await gate.waitForArrivalCount(1)

    let secondToken = fixture.token(
      issuer: fixture.issuer,
      did: fixture.did,
      expiresAt: Date().addingTimeInterval(601)
    )
    let secondProof = try fixture.sessionProof(for: secondToken)
    await #expect(throws: PDSAccessTokenAttestationError.overloaded) {
      _ = try await attestor.attest(
        accessTokenJWT: secondToken,
        authorizationValue: "DPoP \(secondToken)",
        gatewayProof: fixture.gatewayProof,
        sessionProof: secondProof
      )
    }
    await gate.open()
    _ = try await first.value
  }

  @Test("getSession timeout or transport availability failures are never cached")
  func doesNotCacheAvailabilityFailures() async throws {
    let fixture = try Fixture()
    let probes = ProbeCounter()
    let attestor = PDSAccessTokenAttestor(
      authorityResolver: { _ in fixture.authority },
      sessionProbe: { _, _, _ in
        await probes.increment()
        throw PDSAccessTokenAttestationError.unavailable
      }
    )

    for _ in 0..<2 {
      await #expect(throws: PDSAccessTokenAttestationError.unavailable) {
        _ = try await attestor.attest(
          accessTokenJWT: fixture.accessToken,
          authorizationValue: "DPoP \(fixture.accessToken)",
          gatewayProof: fixture.gatewayProof,
          sessionProof: fixture.sessionProof
        )
      }
    }
    #expect(await probes.count == 2)
  }

  @Test("candidate parsing rejects expired, non-PLC, and non-public issuers")
  func strictCandidateParsing() throws {
    let fixture = try Fixture()
    let expired = fixture.token(
      issuer: fixture.issuer,
      did: fixture.did,
      expiresAt: Date(timeIntervalSince1970: 1)
    )
    #expect(throws: PDSAccessTokenAttestationError.invalid) {
      _ = try PDSAccessTokenAttestor.decodeCandidate(expired)
    }
    let didWeb = fixture.token(
      issuer: fixture.issuer,
      did: "did:web:user.public.social",
      expiresAt: Date().addingTimeInterval(300)
    )
    #expect(throws: PDSAccessTokenAttestationError.invalid) {
      _ = try PDSAccessTokenAttestor.decodeCandidate(didWeb)
    }
    let internalIssuer = fixture.token(
      issuer: "https://auth.internal",
      did: fixture.did,
      expiresAt: Date().addingTimeInterval(300)
    )
    #expect(throws: PDSAccessTokenAttestationError.invalid) {
      _ = try PDSAccessTokenAttestor.decodeCandidate(internalIssuer)
    }
  }

  @Test("only absent or empty JWKS can downgrade to active PDS attestation")
  func downgradeClassification() {
    #expect(
      OAuthAccessTokenVerifier.permitsActivePDSFallback(
        error: OAuthAccessTokenVerifier.VerifyError.noJwksCandidates,
        supplementalJwksJSON: nil
      )
    )
    #expect(
      OAuthAccessTokenVerifier.permitsActivePDSFallback(
        error: OAuthAccessTokenVerifier.VerifyError.jwksEmpty("issuer"),
        supplementalJwksJSON: nil
      )
    )
    #expect(
      !OAuthAccessTokenVerifier.permitsActivePDSFallback(
        error: OAuthAccessTokenVerifier.VerifyError.signatureRejected,
        supplementalJwksJSON: nil
      )
    )
    #expect(
      !OAuthAccessTokenVerifier.permitsActivePDSFallback(
        error: OAuthAccessTokenVerifier.VerifyError.jwksEmpty("issuer"),
        supplementalJwksJSON: #"{"keys":[{"kty":"EC"}]}"#
      )
    )
  }

  @Test("gateway DPoP replay keys are proof-key scoped")
  func replayGuard() async throws {
    let guardActor = DPoPReplayGuard(retention: 120, maximumEntries: 10)
    try await guardActor.consume(thumbprint: "key-a", jti: "same-jti")
    await #expect(throws: DPoPReplayGuard.ReplayError.replayed) {
      try await guardActor.consume(thumbprint: "key-a", jti: "same-jti")
    }
    try await guardActor.consume(thumbprint: "key-b", jti: "same-jti")
  }

  @Test("getSession status, nonce, and bounded body handling fail closed")
  func boundedSessionResponses() throws {
    let validBody = Data(#"{"did":"did:plc:viewer","active":true}"#.utf8)
    let session = try PDSAccessTokenAttestor.interpretSessionResponse(
      statusCode: 200,
      nonce: "next",
      body: validBody
    )
    #expect(session.did == "did:plc:viewer")
    #expect(session.active == true)
    #expect(session.nonce == "next")

    #expect(throws: PDSAccessTokenAttestationError.nonceChallenge("retry")) {
      _ = try PDSAccessTokenAttestor.interpretSessionResponse(
        statusCode: 401,
        nonce: "retry",
        body: Data()
      )
    }
    for status in [429, 500, 503] {
      #expect(throws: PDSAccessTokenAttestationError.unavailable) {
        _ = try PDSAccessTokenAttestor.interpretSessionResponse(
          statusCode: status,
          nonce: nil,
          body: Data()
        )
      }
    }
    for body in [Data("not-json".utf8), Data(repeating: 0x41, count: 64 * 1024 + 1)] {
      #expect(throws: PDSAccessTokenAttestationError.invalid) {
        _ = try PDSAccessTokenAttestor.interpretSessionResponse(
          statusCode: 200,
          nonce: nil,
          body: body
        )
      }
    }
    #expect(throws: PDSAccessTokenAttestationError.invalid) {
      _ = try PDSAccessTokenAttestor.interpretSessionResponse(
        statusCode: 401,
        nonce: String(repeating: "n", count: 1_025),
        body: Data()
      )
    }
  }

  @Test("DNS validation follows the IANA special-purpose address registries")
  func publicDNSAddressClassification() {
    let ipv4Cases: [([UInt8], Bool)] = [
      ([0, 0, 0, 1], false), ([10, 0, 0, 1], false), ([100, 64, 0, 1], false),
      ([127, 0, 0, 1], false), ([169, 254, 1, 1], false), ([172, 16, 0, 1], false),
      ([192, 0, 0, 1], false), ([192, 0, 2, 1], false), ([192, 88, 99, 1], false),
      ([192, 168, 1, 1], false), ([198, 18, 0, 1], false), ([198, 51, 100, 1], false),
      ([203, 0, 113, 1], false), ([224, 0, 0, 1], false), ([240, 0, 0, 1], false),
      ([1, 1, 1, 1], true), ([8, 8, 8, 8], true),
    ]
    for (address, expected) in ipv4Cases {
      #expect(PublicDNSAddressValidator.isPublicIPv4(address) == expected)
    }

    let ipv6Cases: [([UInt16], Bool)] = [
      ([0, 0, 0, 0, 0, 0, 0, 0], false),
      ([0, 0, 0, 0, 0, 0, 0, 1], false),
      ([0x64, 0xFF9B, 0, 0, 0, 0, 0x0808, 0x0808], true),
      ([0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 1], false),
      ([0x64, 0xFF9B, 1, 0, 0, 0, 0, 1], false),
      ([0x100, 0, 0, 0, 0, 0, 0, 1], false),
      ([0x100, 0, 0, 1, 0, 0, 0, 1], false),
      ([0x2001, 0, 0, 0, 0, 0, 0, 1], false),
      ([0x2001, 1, 0, 0, 0, 0, 0, 1], true),
      ([0x2001, 0x0002, 0, 0, 0, 0, 0, 1], false),
      ([0x2001, 0x0003, 0, 0, 0, 0, 0, 1], true),
      ([0x2001, 0x0004, 0x0112, 0, 0, 0, 0, 1], true),
      ([0x2001, 0x0005, 0, 0, 0, 0, 0, 1], false),
      ([0x2001, 0x0010, 0, 0, 0, 0, 0, 1], false),
      ([0x2001, 0x0020, 0, 0, 0, 0, 0, 1], true),
      ([0x2001, 0x0030, 0, 0, 0, 0, 0, 1], true),
      ([0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1], false),
      ([0x2002, 0, 0, 0, 0, 0, 0, 1], false),
      ([0x3FFF, 0, 0, 0, 0, 0, 0, 1], false),
      ([0x5F00, 0, 0, 0, 0, 0, 0, 1], false),
      ([0xFC00, 0, 0, 0, 0, 0, 0, 1], false),
      ([0xFE80, 0, 0, 0, 0, 0, 0, 1], false),
      ([0xFF00, 0, 0, 0, 0, 0, 0, 1], false),
      ([0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888], true),
      ([0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111], true),
    ]
    for (groups, expected) in ipv6Cases {
      #expect(PublicDNSAddressValidator.isPublicIPv6(ipv6Bytes(groups)) == expected)
    }
  }

  @Test("DNS deadline returns while a blocking resolver retains its bounded permit")
  func boundedDNSResolutionDeadline() async throws {
    let admission = PublicDNSResolverAdmission(maximumConcurrentResolutions: 1)
    let clock = ContinuousClock()
    let first = Task {
      try await PublicDNSAddressValidator.validatedAddress(
        for: "https://slow.public.social",
        deadline: clock.now.advanced(by: .milliseconds(20)),
        admission: admission,
        resolver: { _ in
          Thread.sleep(forTimeInterval: 0.15)
          return ["1.1.1.1"]
        }
      )
    }
    await #expect(throws: PDSAccessTokenAttestationError.unavailable) {
      _ = try await first.value
    }

    await #expect(throws: PDSAccessTokenAttestationError.unavailable) {
      _ = try await PublicDNSAddressValidator.validatedAddress(
        for: "https://other.public.social",
        deadline: clock.now.advanced(by: .seconds(1)),
        admission: admission,
        resolver: { _ in ["8.8.8.8"] }
      )
    }

    let resolverReleaseDeadline = clock.now.advanced(by: .seconds(1))
    while await admission.activeCount() != 0, clock.now < resolverReleaseDeadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await admission.activeCount() == 0)
    let recovered = try await PublicDNSAddressValidator.validatedAddress(
      for: "https://recovered.public.social",
      deadline: clock.now.advanced(by: .seconds(1)),
      admission: admission,
      resolver: { _ in ["8.8.8.8"] }
    )
    #expect(recovered == "8.8.8.8")
  }

  @Test("DNS caller cancellation returns promptly without releasing a blocked resolver permit")
  func boundedDNSResolutionCancellation() async throws {
    let admission = PublicDNSResolverAdmission(maximumConcurrentResolutions: 1)
    let clock = ContinuousClock()
    let first = Task {
      try await PublicDNSAddressValidator.validatedAddress(
        for: "https://cancelled.public.social",
        deadline: clock.now.advanced(by: .seconds(1)),
        admission: admission,
        resolver: { _ in
          Thread.sleep(forTimeInterval: 0.15)
          return ["1.1.1.1"]
        }
      )
    }
    while await admission.activeCount() == 0 { await Task.yield() }
    first.cancel()
    await #expect(throws: PDSAccessTokenAttestationError.unavailable) {
      _ = try await first.value
    }

    #expect(await admission.activeCount() == 1)
    await #expect(throws: PDSAccessTokenAttestationError.unavailable) {
      _ = try await PublicDNSAddressValidator.validatedAddress(
        for: "https://other.public.social",
        deadline: clock.now.advanced(by: .seconds(1)),
        admission: admission,
        resolver: { _ in ["8.8.8.8"] }
      )
    }
    let resolverReleaseDeadline = clock.now.advanced(by: .seconds(1))
    while await admission.activeCount() != 0, clock.now < resolverReleaseDeadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await admission.activeCount() == 0)
  }

  @Test("one absolute PDS deadline includes a trickled response body")
  func boundedPDSResponseBodyDeadline() async throws {
    let stream = AsyncStream<ByteBuffer> { continuation in
      continuation.yield(ByteBuffer(bytes: Array("{".utf8)))
      Task {
        try? await Task.sleep(for: .milliseconds(150))
        continuation.yield(ByteBuffer(bytes: Array(#""did":"did:plc:late"}"#.utf8)))
        continuation.finish()
      }
    }
    let response = HTTPClientResponse(status: .ok, body: .stream(stream))
    let clock = ContinuousClock()
    let startedAt = clock.now

    await #expect(throws: PDSAccessTokenAttestationError.unavailable) {
      _ = try await PDSAccessTokenAttestor.consumePinnedPDSResponse(
        response,
        deadline: startedAt.advanced(by: .milliseconds(20)),
        maximumBodyBytes: 64 * 1024
      )
    }
    #expect(startedAt.duration(to: clock.now) < .milliseconds(120))
  }

  @Test("session proof header is exactly one bounded value")
  func boundedSessionProofHeader() {
    #expect(ATProtoSessionDPoP.validatedProof("  proof.jwt.value  ") == "proof.jwt.value")
    #expect(ATProtoSessionDPoP.validatedProof(nil) == nil)
    #expect(ATProtoSessionDPoP.validatedProof("   ") == nil)
    #expect(ATProtoSessionDPoP.validatedProof("proof-one,proof-two") == nil)
    #expect(
      ATProtoSessionDPoP.validatedProof(
        String(repeating: "p", count: ATProtoSessionDPoP.maximumProofBytes + 1)
      ) == nil
    )
  }

  private func ipv6Bytes(_ groups: [UInt16]) -> [UInt8] {
    groups.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
  }
}

private struct Fixture: Sendable {
  let did = "did:plc:attestationviewer"
  let issuer = "https://auth.public.social"
  let pdsBase = "https://pds.public.social"
  let key: P256.Signing.PrivateKey
  let thumbprint: String
  let accessToken: String
  let sessionProof: String

  var gatewayProof: DPoPProofVerifier.VerifiedProof {
    .init(jwkThumbprint: thumbprint, jti: "gateway-jti")
  }
  var authority: PDSAccessTokenAttestor.Authority {
    .init(pdsBase: pdsBase, authorizationServers: [issuer])
  }

  init() throws {
    let key = P256.Signing.PrivateKey()
    self.key = key
    self.thumbprint = try Self.thumbprint(key: key)
    self.accessToken = Self.token(
      issuer: issuer,
      did: did,
      expiresAt: Date().addingTimeInterval(600),
      thumbprint: thumbprint
    )
    self.sessionProof = try Self.proof(
      key: key,
      accessToken: accessToken,
      url: "\(pdsBase)/xrpc/com.atproto.server.getSession"
    )
  }

  func token(issuer: String, did: String, expiresAt: Date) -> String {
    Self.token(
      issuer: issuer,
      did: did,
      expiresAt: expiresAt,
      thumbprint: thumbprint
    )
  }

  func sessionProof(for accessToken: String) throws -> String {
    try Self.proof(
      key: key,
      accessToken: accessToken,
      url: "\(pdsBase)/xrpc/com.atproto.server.getSession"
    )
  }

  private static func token(
    issuer: String,
    did: String,
    expiresAt: Date,
    thumbprint: String
  ) -> String {
    let header = encoded(["alg": "ES256", "typ": "JWT"])
    let payload = encoded([
      "iss": issuer,
      "sub": did,
      "exp": Int(expiresAt.timeIntervalSince1970),
      "cnf": ["jkt": thumbprint],
      "client_id": "https://client.public.social/metadata.json",
    ] as [String: Any])
    return "\(header).\(payload).issuer-signature-validated-by-pds"
  }

  private static func proof(key: P256.Signing.PrivateKey, accessToken: String, url: String) throws
    -> String
  {
    let coordinates = key.publicKey.x963Representation.dropFirst()
    let jwk: [String: Any] = [
      "kty": "EC",
      "crv": "P-256",
      "x": Base64URL.encodeNoPadding(data: Data(coordinates.prefix(32))),
      "y": Base64URL.encodeNoPadding(data: Data(coordinates.suffix(32))),
    ]
    let header = encoded(["alg": "ES256", "typ": "dpop+jwt", "jwk": jwk] as [String: Any])
    let payload = encoded([
      "jti": UUID().uuidString,
      "iat": Int(Date().timeIntervalSince1970),
      "htm": "GET",
      "htu": url,
      "ath": AccessTokenAth.expectedAth(accessTokenJWT: accessToken),
    ] as [String: Any])
    let signingInput = Data("\(header).\(payload)".utf8)
    let signature = try key.signature(for: SHA256.hash(data: signingInput))
    return "\(header).\(payload).\(Base64URL.encodeNoPadding(data: signature.rawRepresentation))"
  }

  private static func thumbprint(key: P256.Signing.PrivateKey) throws -> String {
    let coordinates = key.publicKey.x963Representation.dropFirst()
    let canonical: [String: String] = [
      "crv": "P-256",
      "kty": "EC",
      "x": Base64URL.encodeNoPadding(data: Data(coordinates.prefix(32))),
      "y": Base64URL.encodeNoPadding(data: Data(coordinates.suffix(32))),
    ]
    let data = try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])
    return Base64URL.encodeNoPadding(digest: SHA256.hash(data: data))
  }

  private static func encoded(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return Base64URL.encodeNoPadding(data: data)
  }
}
