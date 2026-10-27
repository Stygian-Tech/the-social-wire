import Foundation

/// A workspace cannot reuse a later account's credentials or accept its old responses.
@MainActor
final class SocialSessionScope {
    let viewerDID: String?
    private let auth: ATProtoOAuthService
    private var isActive = true

    init(viewerDID: String?, auth: ATProtoOAuthService) {
        self.viewerDID = viewerDID
        self.auth = auth
    }

    func invalidate() {
        isActive = false
    }

    func validate() throws {
        guard isActive, let viewerDID, auth.session?.did == viewerDID else {
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
