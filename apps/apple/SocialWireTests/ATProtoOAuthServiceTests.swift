import Foundation
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

    @Test("Existing scopes restore normally while PDS writes require explicit reauthorization")
    func readStatePermissionsDoNotInvalidateOrdinarySessions() {
        let oldScopes = ATProtoOAuthService.scopes.split(separator: " ")
            .map(String.init).filter { !ATProtoOAuthService.pdsReadStateScopes.contains($0) }
            .joined(separator: " ")
        #expect(ATProtoOAuthService.hasRequiredFeatureScopes(oldScopes))
        #expect(!ATProtoOAuthService.hasPDSReadStateScopes(oldScopes))
        #expect(ATProtoOAuthService.hasPDSReadStateScopes(ATProtoOAuthService.scopes))
        #expect(!ATProtoOAuthService.hasPDSReadStateScopes(nil))
        let createOnlyChunk = ATProtoOAuthService.scopes.replacingOccurrences(
            of: "repo:app.thesocialwire.readStateChunk?action=create&action=update",
            with: "repo:app.thesocialwire.readStateChunk?action=create")
        #expect(!ATProtoOAuthService.hasPDSReadStateScopes(createOnlyChunk))
        #expect(ATProtoOAuthService.hasRequiredFeatureScopes(createOnlyChunk))
    }

    @Test("universal Apple scopes cover parity actions and trigger old-session reauthorization")
    func universalParityScopes() {
        let actual = Set(ATProtoOAuthService.scopes.split(separator: " ").map(String.init))
        #expect(ATProtoOAuthService.requiredFeatureScopes.isSubset(of: actual))
        #expect(ATProtoOAuthService.hasRequiredFeatureScopes(ATProtoOAuthService.scopes))
        #expect(!ATProtoOAuthService.hasRequiredFeatureScopes("atproto"))
        #expect(!ATProtoOAuthService.hasRequiredFeatureScopes(nil))
    }
}
