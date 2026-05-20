import Testing
@testable import SocialWire

@Suite("ATProtoOAuthService")
@MainActor
struct ATProtoOAuthServiceTests {
    @Test("code verifier length within PKCE bounds")
    func codeVerifierLengthWithinPKCEBounds() {
        let verifier = ATProtoOAuthService.generateCodeVerifier()
        #expect(verifier.count >= 43)
        #expect(verifier.count <= 128)
    }

    @Test("PAR request fields include client ID and redirect")
    func parRequestFieldsIncludeClientIdAndRedirect() {
        let fields = ATProtoOAuthService.parRequestFields(
            codeChallenge: "challenge",
            state: "state",
            loginHint: "did:plc:test"
        )
        #expect(fields["client_id"] == ATProtoOAuthConfig.clientID)
        #expect(fields["redirect_uri"] == ATProtoOAuthConfig.redirectURI)
    }
}
