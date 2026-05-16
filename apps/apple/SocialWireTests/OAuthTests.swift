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

    func testNativeRedirectURIUsesReversedHostSingleSlash() {
        let pair = ATProtoOAuthConfig.nativeRedirectPair(forClientID: ATProtoOAuthConfig.defaultClientID)
        XCTAssertEqual(pair.redirectURI, "app.thesocialwire:/oauth/callback")
        XCTAssertFalse(pair.redirectURI.contains("://"))
        XCTAssertEqual(pair.scheme, "app.thesocialwire")
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
}
