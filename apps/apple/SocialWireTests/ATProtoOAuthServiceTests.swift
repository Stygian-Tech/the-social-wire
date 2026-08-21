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

    @Test("OAuth scopes include viewer moderation RPCs for the Bluesky AppView")
    func scopesIncludeViewerModerationRPCs() {
        let audience = "?aud=did:web:api.bsky.app%23bsky_appview"
        let expected = [
            "app.bsky.actor.getPreferences",
            "app.bsky.graph.getBlocks",
            "app.bsky.graph.getMutes",
            "app.bsky.graph.getListMutes",
            "app.bsky.graph.getListBlocks",
            "app.bsky.graph.getList",
        ].map { "rpc:\($0)\(audience)" }
        let actual = Set(ATProtoOAuthService.scopes.split(separator: " ").map(String.init))
        #expect(expected.allSatisfy(actual.contains))
    }
}
