import Foundation
import Testing
@testable import SocialWire

@Suite("ATProto session DPoP")
struct ATProtoSessionDPoPTests {
    @Test("session proof targets getSession with token binding and the PDS nonce")
    func sessionProofTargetsGetSession() async throws {
        let service = DPoPService()
        let session = AuthSession(
            did: "did:plc:viewer",
            pdsURL: try #require(URL(string: "https://pds.example")),
            tokenEndpoint: try #require(URL(string: "https://issuer.example/oauth/token")),
            accessToken: "access-token",
            refreshToken: "refresh-token",
            tokenType: "DPoP",
            expiresAt: Date().addingTimeInterval(300)
        )
        let url = ATProtoSessionDPoP.getSessionURL(for: session)
        await service.updateNonce("pds-nonce", for: url)

        let proof = try await service.proof(method: "GET", url: url, accessToken: session.accessToken)
        let payload = try Self.decodePayload(proof)

        #expect(payload["htm"] as? String == "GET")
        #expect(payload["htu"] as? String == "https://pds.example/xrpc/com.atproto.server.getSession")
        #expect(payload["nonce"] as? String == "pds-nonce")
        #expect(payload["ath"] as? String == "Pxa-1wifRlPl7yG_0oJNfzqq7MelmOfonFgOFgapzFI")
    }

    @Test("dedicated nonce challenge is isolated from ordinary Gateway DPoP")
    func dedicatedNonceChallenge() throws {
        let url = try #require(URL(string: "https://api.thesocialwire.app/v1/appview/feed"))
        let challenged = try #require(HTTPURLResponse(
            url: url,
            statusCode: 401,
            httpVersion: nil,
            headerFields: [ATProtoSessionDPoP.nonceHeaderName: "pds-nonce"]
        ))
        let ordinary = try #require(HTTPURLResponse(
            url: url,
            statusCode: 401,
            httpVersion: nil,
            headerFields: ["DPoP-Nonce": "gateway-nonce"]
        ))

        #expect(ATProtoSessionDPoP.isNonceChallenge(challenged))
        #expect(!ATProtoSessionDPoP.isNonceChallenge(ordinary))
    }

    @Test("attestation receipt and refresh signal use dedicated headers")
    func attestationReceiptAndRefreshSignal() throws {
        let url = try #require(URL(string: "https://api.thesocialwire.app/v1/appview/feed"))
        let preflight = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [ATProtoSessionDPoP.receiptHeaderName: " receipt-value "]
        ))
        let required = try #require(HTTPURLResponse(
            url: url,
            statusCode: 428,
            httpVersion: nil,
            headerFields: [ATProtoSessionDPoP.attestationRequiredHeaderName: "true"]
        ))
        let unrelated = try #require(HTTPURLResponse(
            url: url,
            statusCode: 428,
            httpVersion: nil,
            headerFields: [ATProtoSessionDPoP.attestationRequiredHeaderName: "false"]
        ))

        #expect(ATProtoSessionDPoP.receipt(from: preflight) == "receipt-value")
        #expect(ATProtoSessionDPoP.isAttestationRequired(required))
        #expect(!ATProtoSessionDPoP.isAttestationRequired(unrelated))
    }

    @Test("nonce cache isolates two ports on the same host")
    func nonceCacheIncludesEffectivePort() async throws {
        let service = DPoPService()
        let first = try #require(URL(string: "https://pds.example:8443/xrpc/com.atproto.server.getSession"))
        let second = try #require(URL(string: "https://pds.example:9443/xrpc/com.atproto.server.getSession"))

        await service.updateNonce("port-8443-nonce", for: first)
        let firstProof = try await service.proof(method: "GET", url: first)
        let secondProofBeforeUpdate = try await service.proof(method: "GET", url: second)

        #expect(try Self.decodePayload(firstProof)["nonce"] as? String == "port-8443-nonce")
        #expect(try Self.decodePayload(secondProofBeforeUpdate)["nonce"] == nil)

        await service.updateNonce("port-9443-nonce", for: second)
        let secondProof = try await service.proof(method: "GET", url: second)
        #expect(try Self.decodePayload(secondProof)["nonce"] as? String == "port-9443-nonce")
    }

    @Test("implicit and explicit HTTPS ports share one nonce cache key")
    func defaultHTTPSPortIsCanonical() async throws {
        let service = DPoPService()
        let implicit = try #require(URL(string: "https://pds.example/xrpc/com.atproto.server.getSession"))
        let explicit = try #require(URL(string: "https://pds.example:443/xrpc/com.atproto.server.getSession"))

        await service.updateNonce("https-default-nonce", for: implicit)
        let proof = try await service.proof(method: "GET", url: explicit)

        #expect(try Self.decodePayload(proof)["nonce"] as? String == "https-default-nonce")
    }

    private static func decodePayload(_ proof: String) throws -> [String: Any] {
        let segments = proof.split(separator: ".")
        #expect(segments.count == 3)
        let raw = String(try #require(segments.dropFirst().first))
        let padding = String(repeating: "=", count: (4 - raw.count % 4) % 4)
        let base64 = raw.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        let data = try #require(Data(base64Encoded: base64))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
