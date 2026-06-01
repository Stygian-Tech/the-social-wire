import Foundation
import Testing
@testable import SocialWire

@Suite("OAuth")
@MainActor
struct OAuthTests {
    @Test("authorization redirect URL uses PAR follow-on shape")
    func authorizationRedirectURLUsesPARFollowOnShape() throws {
        let endpoint = URL(string: "https://entryway.example/oauth/authorize")!
        let url = try ATProtoOAuthService.authorizationRedirectURL(
            authorizationEndpoint: endpoint,
            requestURI: "urn:ietf:params:oauth:request_uri:bwc4JK-test"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["client_id"] == ATProtoOAuthConfig.clientID)
        #expect(query["request_uri"] == "urn:ietf:params:oauth:request_uri:bwc4JK-test")
        #expect(query["redirect_uri"] == nil)
        #expect(query["scope"] == nil)
    }

    @Test("OAuth redirects match reversed FQDN of client metadata URL")
    func oauthRedirectsMatchReversedFqdnOfClientMetadataURL() {
        let pair = ATProtoOAuthConfig.nativeRedirectPair(forClientID: ATProtoOAuthConfig.clientID)
        #expect(ATProtoOAuthConfig.callbackURLScheme == pair.scheme)
        #expect(ATProtoOAuthConfig.redirectURI == pair.redirectURI)
        #expect(!ATProtoOAuthConfig.redirectURI.contains("://"))
    }

    @Test("native redirect pairs for Swift API hosts use ATProto reversal")
    func nativeRedirectPairsForSwiftApiHostsUseAtprotoReversal() {
        let prod = ATProtoOAuthConfig.nativeRedirectPair(forClientID: "https://api.thesocialwire.app/ios-client-metadata.json")
        #expect(prod.scheme == "app.thesocialwire.api")
        #expect(prod.redirectURI == "app.thesocialwire.api:/oauth/callback")

        let testing = ATProtoOAuthConfig.nativeRedirectPair(forClientID: "https://api.testing.thesocialwire.app/ios-client-metadata.json")
        #expect(testing.scheme == "app.thesocialwire.testing.api")
        #expect(testing.redirectURI == "app.thesocialwire.testing.api:/oauth/callback")
    }

    @Test("native redirect pair for marketing host matches web metadata")
    func nativeRedirectPairForMarketingHostMatchesWebMetadata() {
        let pair = ATProtoOAuthConfig.nativeRedirectPair(forClientID: "https://thesocialwire.app/ios-client-metadata.json")
        #expect(pair.scheme == "app.thesocialwire")
        #expect(pair.redirectURI == "app.thesocialwire:/oauth/callback")
    }

    @Test("native URL scheme reverses host labels")
    func nativeURLSchemeReversesHostLabels() {
        #expect(ATProtoOAuthConfig.nativeURLScheme(forHost: "thesocialwire.app") == "app.thesocialwire")
        #expect(ATProtoOAuthConfig.nativeURLScheme(forHost: "app.example.com") == "com.example.app")
    }

    @Test("PAR request fields include scopes and login hint")
    func parRequestFieldsIncludeScopesAndLoginHint() {
        let fields = ATProtoOAuthService.parRequestFields(codeChallenge: "ch", state: "st", loginHint: "did:plc:test")
        #expect(fields["response_type"] == "code")
        #expect(fields["client_id"] == ATProtoOAuthConfig.clientID)
        #expect(fields["code_challenge"] == "ch")
        #expect(fields["code_challenge_method"] == "S256")
        #expect(fields["redirect_uri"] == ATProtoOAuthConfig.redirectURI)
        #expect(fields["state"] == "st")
        #expect(fields["login_hint"] == "did:plc:test")
        #expect(fields["scope"]?.contains("repo:app.thesocialwire.entryReadState") == true)
    }

    @Test("PKCE challenge is stable for verifier")
    func pkceChallengeIsStableForVerifier() {
        let challenge = ATProtoOAuthService.codeChallenge(from: "abcdefghijklmnopqrstuvwxyz0123456789")
        #expect(!challenge.contains("="))
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
    }

    @Test("default client uses testing API when debugging or beta flag")
    func defaultClientUsesTestingApiWhenDebuggingOrBetaFlag() {
        let id = ATProtoOAuthConfig.defaultClientID
        #expect(id.hasSuffix("/ios-client-metadata.json"))
        #if DEBUG || SOCIALWIRE_TESTING_API
        #expect(id == "https://api.testing.thesocialwire.app/ios-client-metadata.json")
        #else
        #expect(id == "https://api.thesocialwire.app/ios-client-metadata.json")
        #endif
    }
}
