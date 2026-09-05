import Foundation

enum SocialWireError: LocalizedError {
    case notAuthenticated
    case badResponse(String)
    case sembleCollectionUnavailable(String)
    /// `app.thesocialwire.appview.*` is not mounted (`ENABLE_THIN_APPVIEW` off on the gateway).
    case appViewUnavailable
    case cursorExpired
    case invalidURL
    case invalidATURI
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Sign in to continue."
        case .badResponse(let message): message
        case .sembleCollectionUnavailable(let message): message
        case .cursorExpired: "This edition has expired. Refreshing the latest stories."
        case .appViewUnavailable: "Thin AppView is not enabled on this API host."
        case .invalidURL: "The URL is invalid."
        case .invalidATURI: "The AT-URI is invalid."
        case .unsupported: "This action is not supported yet."
        }
    }

    static func isExpiredFeedCursor(statusCode: Int, body: Data) -> Bool {
        guard statusCode == 410,
              let envelope = try? JSONDecoder().decode(CursorErrorEnvelope.self, from: body)
        else { return false }
        return envelope.error == "CursorExpired"
    }

    func shouldRestartFeed(cursor: String?) -> Bool {
        guard let cursor, !cursor.isEmpty else { return false }
        if case .cursorExpired = self { return true }
        return false
    }

    private struct CursorErrorEnvelope: Decodable {
        let error: String
    }

}
