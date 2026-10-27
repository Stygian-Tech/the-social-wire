import Foundation

/// A workspace cannot reuse a later account's credentials or accept its old responses.
@MainActor
final class SocialSessionScope {
    let viewerDID: String?
    private let pdsURL: URL?
    private let tokenEndpoint: URL?
    private let loginIdentity: UUID
    private let auth: ATProtoOAuthService
    private var isActive = true

    init(viewerDID: String?, auth: ATProtoOAuthService) {
        self.viewerDID = viewerDID
        self.pdsURL = auth.session?.pdsURL
        self.tokenEndpoint = auth.session?.tokenEndpoint
        self.loginIdentity = auth.loginIdentity
        self.auth = auth
    }

    init(session: AuthSession?, loginIdentity: UUID, auth: ATProtoOAuthService) {
        self.viewerDID = session?.did
        self.pdsURL = session?.pdsURL
        self.tokenEndpoint = session?.tokenEndpoint
        self.loginIdentity = loginIdentity
        self.auth = auth
    }

    // Token rotation preserves workspace state; endpoint changes and explicit logins do not.
    func matches(session: AuthSession?, loginIdentity: UUID) -> Bool {
        isActive && viewerDID == session?.did
            && pdsURL == session?.pdsURL
            && tokenEndpoint == session?.tokenEndpoint
            && self.loginIdentity == loginIdentity
    }

    func invalidate() {
        isActive = false
    }

    func validate() throws {
        guard viewerDID != nil, matches(session: auth.session, loginIdentity: auth.loginIdentity) else {
            throw CancellationError()
        }
    }

    nonisolated func transport(
        using underlying: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            try await self.validate()
            let response = try await underlying(request)
            try await self.validate()
            return response
        }
    }
}
