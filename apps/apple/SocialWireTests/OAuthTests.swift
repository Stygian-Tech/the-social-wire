import XCTest
@testable import SocialWire

@MainActor
final class OAuthTests: XCTestCase {
    func testAuthorizationRedirectURLUsesPARFollowOnShape() throws {
        let endpoint = URL(string: "https://entryway.example/oauth/authorize")!
        let url = try ATProtoOAuthService.authorizationRedirectURL(
            authorizationEndpoint: endpoint,
            requestURI: "urn:ietf:params:oauth:request_uri:bwc4JK-test"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["client_id"], ATProtoOAuthConfig.clientID)
        XCTAssertEqual(query["request_uri"], "urn:ietf:params:oauth:request_uri:bwc4JK-test")
        XCTAssertNil(query["redirect_uri"])
        XCTAssertNil(query["scope"])
    }

    func testOAuthRedirectsMatchReversedFqdnOfClientMetadataURL() {
        let pair = ATProtoOAuthConfig.nativeRedirectPair(forClientID: ATProtoOAuthConfig.clientID)
        XCTAssertEqual(ATProtoOAuthConfig.callbackURLScheme, pair.scheme)
        XCTAssertEqual(ATProtoOAuthConfig.redirectURI, pair.redirectURI)
        XCTAssertFalse(ATProtoOAuthConfig.redirectURI.contains("://"))
    }

    func testNativeRedirectPairsForSwiftApiHostsUseAtprotoReversal() {
        let prod = ATProtoOAuthConfig.nativeRedirectPair(forClientID: "https://api.thesocialwire.app/ios-client-metadata.json")
        XCTAssertEqual(prod.scheme, "app.thesocialwire.api")
        XCTAssertEqual(prod.redirectURI, "app.thesocialwire.api:/oauth/callback")

        let testing = ATProtoOAuthConfig.nativeRedirectPair(forClientID: "https://api.testing.thesocialwire.app/ios-client-metadata.json")
        XCTAssertEqual(testing.scheme, "app.thesocialwire.testing.api")
        XCTAssertEqual(testing.redirectURI, "app.thesocialwire.testing.api:/oauth/callback")
    }

    func testNativeRedirectPairForMarketingHostMatchesWebMetadata() {
        let pair = ATProtoOAuthConfig.nativeRedirectPair(forClientID: "https://thesocialwire.app/ios-client-metadata.json")
        XCTAssertEqual(pair.scheme, "app.thesocialwire")
        XCTAssertEqual(pair.redirectURI, "app.thesocialwire:/oauth/callback")
    }

    func testNativeURLSchemeReversesHostLabels() {
        XCTAssertEqual(ATProtoOAuthConfig.nativeURLScheme(forHost: "thesocialwire.app"), "app.thesocialwire")
        XCTAssertEqual(ATProtoOAuthConfig.nativeURLScheme(forHost: "app.example.com"), "com.example.app")
    }

    func testPARRequestFieldsIncludeScopesAndLoginHint() {
        let fields = ATProtoOAuthService.parRequestFields(codeChallenge: "ch", state: "st", loginHint: "did:plc:test")
        XCTAssertEqual(fields["response_type"], "code")
        XCTAssertEqual(fields["client_id"], ATProtoOAuthConfig.clientID)
        XCTAssertEqual(fields["code_challenge"], "ch")
        XCTAssertEqual(fields["code_challenge_method"], "S256")
        XCTAssertEqual(fields["redirect_uri"], ATProtoOAuthConfig.redirectURI)
        XCTAssertEqual(fields["state"], "st")
        XCTAssertEqual(fields["login_hint"], "did:plc:test")
        XCTAssertTrue(fields["scope"]?.contains("repo:com.thesocialwire.entryReadState") == true)
    }

    func testPKCEChallengeIsStableForVerifier() {
        let challenge = ATProtoOAuthService.codeChallenge(from: "abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertFalse(challenge.contains("="))
        XCTAssertFalse(challenge.contains("+"))
        XCTAssertFalse(challenge.contains("/"))
    }

    func testDefaultClientUsesTestingApiWhenDebuggingOrBetaFlag() throws {
        let id = ATProtoOAuthConfig.defaultClientID
        XCTAssertTrue(id.hasSuffix("/ios-client-metadata.json"))
        #if DEBUG || SOCIALWIRE_TESTING_API
        XCTAssertEqual(id, "https://api.testing.thesocialwire.app/ios-client-metadata.json")
        #else
        XCTAssertEqual(id, "https://api.thesocialwire.app/ios-client-metadata.json")
        #endif
    }
}
