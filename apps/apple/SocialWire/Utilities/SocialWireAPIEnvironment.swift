import Foundation

/// Base URL for the deployed Swift API (OAuth metadata, future authenticated sync/cache).
enum SocialWireAPIEnvironment {
    private static let productionBaseURLString = "https://api.thesocialwire.app"
    private static let testingBaseURLString = "https://api.testing.thesocialwire.app"

    /// HTTPS API origin without a trailing slash. Debug builds use the testing fleet; Release uses production.
    static var baseURLString: String {
        #if DEBUG
        testingBaseURLString
        #else
        productionBaseURLString
        #endif
    }

    static var baseURL: URL {
        guard let url = URL(string: baseURLString), url.scheme == "https", url.host != nil else {
            preconditionFailure("Invalid Social Wire API base URL.")
        }
        return url
    }

    /// Discoverable OAuth `client_id` (`GET` returns native client metadata JSON).
    static var iosClientMetadataURL: URL {
        baseURL.appendingPathComponent("ios-client-metadata.json")
    }
}
