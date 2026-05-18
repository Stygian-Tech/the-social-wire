import Foundation

/// Base URL for the deployed Swift API (OAuth metadata, future authenticated sync/cache).
enum SocialWireAPIEnvironment {
    private static let productionBaseURLString = "https://api.thesocialwire.app"
    private static let testingBaseURLString = "https://api.testing.thesocialwire.app"

    /// Debug simulators/devices and **TestFlight** (`Beta`) builds hit the testing API.
    /// **App Store** Release builds (`Release`) use production.
    static var baseURLString: String {
        #if DEBUG || SOCIALWIRE_TESTING_API
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

    /// Discoverable OAuth **`client_id`** (**`GET .../ios-client-metadata.json`**).
    static var iosClientMetadataURL: URL {
        baseURL.appendingPathComponent("ios-client-metadata.json")
    }
}
