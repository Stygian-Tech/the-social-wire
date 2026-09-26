import AuthenticationServices
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
            of: "repo:app.thesocialwire.readStateChunk?action=create&action=update&action=delete",
            with: "repo:app.thesocialwire.readStateChunk?action=create")
        #expect(!ATProtoOAuthService.hasPDSReadStateScopes(createOnlyChunk))
        #expect(ATProtoOAuthService.hasRequiredFeatureScopes(createOnlyChunk))
    }

    @Test("Optional cleanup permission never blocks ordinary PDS history writes")
    func cleanupPermissionIsIndependentOfHistoryWrites() {
        let writeOnly = "repo:app.thesocialwire.readState?action=create&action=update repo:app.thesocialwire.readStateChunk?action=create&action=update"
        #expect(ATProtoOAuthService.hasPDSReadStateScopes(writeOnly))
        #expect(!ATProtoOAuthService.hasPDSReadStateCleanupScopes(writeOnly))
        #expect(ATProtoOAuthService.hasPDSReadStateScopes(ATProtoOAuthService.scopes))
        #expect(ATProtoOAuthService.hasPDSReadStateCleanupScopes(ATProtoOAuthService.scopes))
        #expect(!ATProtoOAuthService.hasPDSReadStateCleanupScopes(nil))
        let reordered = "repo:app.thesocialwire.readState?action=update&action=create repo:app.thesocialwire.readStateChunk?action=delete&action=update&action=create"
        #expect(ATProtoOAuthService.hasPDSReadStateScopes(reordered))
        #expect(ATProtoOAuthService.hasPDSReadStateCleanupScopes(reordered))
        #expect(!ATProtoOAuthService.hasPDSReadStateScopes(writeOnly + "&unknownConstraint=other"))
    }

    @Test("universal Apple scopes declare parity action permissions")
    func universalParityScopes() {
        let actual = Set(ATProtoOAuthService.scopes.split(separator: " ").map(String.init))
        #expect(ATProtoOAuthService.requiredFeatureScopes.isSubset(of: actual))
        #expect(ATProtoOAuthService.hasRequiredFeatureScopes(ATProtoOAuthService.scopes))
        #expect(!ATProtoOAuthService.hasRequiredFeatureScopes("atproto"))
        #expect(!ATProtoOAuthService.hasRequiredFeatureScopes(nil))
    }

    @Test("browser cancellation is recognized without hiding other OAuth failures")
    func recognizesBrowserCancellation() {
        let cancellation = NSError(
            domain: ASWebAuthenticationSessionError.errorDomain,
            code: ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
        )
        let failure = NSError(
            domain: ASWebAuthenticationSessionError.errorDomain,
            code: ASWebAuthenticationSessionError.Code.presentationContextNotProvided.rawValue
        )
        let requestCancellation = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled
        )
        let wrappedCancellation = NSError(
            domain: "OAuthWrapper",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: requestCancellation]
        )

        #expect(ATProtoOAuthService.isUserCancellation(cancellation))
        #expect(ATProtoOAuthService.isUserCancellation(CancellationError()))
        #expect(ATProtoOAuthService.isUserCancellation(requestCancellation))
        #expect(ATProtoOAuthService.isUserCancellation(wrappedCancellation))
        #expect(!ATProtoOAuthService.isUserCancellation(failure))
        #expect(ATProtoOAuthService.isOAuthCancellation(code: "access_denied", description: "Cancelled"))
        #expect(ATProtoOAuthService.isOAuthCancellation(code: "cancelled", description: nil))
        #expect(!ATProtoOAuthService.isOAuthCancellation(code: "server_error", description: "Try again"))
    }
}
