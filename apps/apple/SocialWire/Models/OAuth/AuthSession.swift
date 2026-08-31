import Foundation

struct AuthSession: Codable, Equatable, Sendable {
    var did: String
    var pdsURL: URL
    /// Authorization-server token endpoint (from `/.well-known/oauth-authorization-server`).
    var tokenEndpoint: URL
    var accessToken: String
    var refreshToken: String
    var tokenType: String
    var scope: String?
    var expiresAt: Date
}
