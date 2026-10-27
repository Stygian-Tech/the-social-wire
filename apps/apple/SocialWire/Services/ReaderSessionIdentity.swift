import Foundation

/// Reader requests belong to one login and its discovered OAuth endpoints.
struct ReaderSessionIdentity {
    private let viewerDID: String?
    private let pdsURL: URL?
    private let tokenEndpoint: URL?
    private let loginIdentity: UUID

    init(session: AuthSession?, loginIdentity: UUID) {
        viewerDID = session?.did
        pdsURL = session?.pdsURL
        tokenEndpoint = session?.tokenEndpoint
        self.loginIdentity = loginIdentity
    }

    // Refreshing tokens preserves reader state; replacing the login does not.
    func matches(session: AuthSession?, loginIdentity: UUID) -> Bool {
        viewerDID == session?.did
            && pdsURL == session?.pdsURL
            && tokenEndpoint == session?.tokenEndpoint
            && self.loginIdentity == loginIdentity
    }
}
