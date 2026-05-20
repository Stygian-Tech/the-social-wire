import Foundation

enum SocialWireError: LocalizedError {
    case notAuthenticated
    case badResponse(String)
    /// `GET /v1/appview/*` is not mounted (`ENABLE_THIN_APPVIEW` off on the gateway).
    case appViewUnavailable
    case invalidURL
    case invalidATURI
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Sign in to continue."
        case .badResponse(let message): message
        case .appViewUnavailable: "Thin AppView is not enabled on this API host."
        case .invalidURL: "The URL is invalid."
        case .invalidATURI: "The AT-URI is invalid."
        case .unsupported: "This action is not supported yet."
        }
    }
}
