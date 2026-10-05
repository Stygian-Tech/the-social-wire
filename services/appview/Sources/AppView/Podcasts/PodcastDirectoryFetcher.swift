import AsyncHTTPClient
import Foundation
import GatewayCore
import ThinAppViewCore

/// Fixed provider, pinned public DNS, no cross-URL redirects or auth, eight-second total deadline.
enum PodcastDirectoryFetcher {
  static func requestURL(_ query: String) throws -> String {
    guard var components = URLComponents(string: "https://api.podcastindex.org/search") else { throw PodcastDirectoryError.unavailable }
    components.queryItems = [URLQueryItem(name: "term", value: query)]
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    guard let url = components.url?.absoluteString else { throw PodcastDirectoryError.unavailable }
    return url
  }
  static func fetch(_ query: String, http: HTTPClient) async throws -> Data {
    let query = try PodcastDirectoryQuery.validate(PodcastSearchRequest(query: query, scope: "directory"))
    let url = try requestURL(query)
    do {
      return try await PublicMediaFetcher.fetch(url: url, httpClient: http, maximumBytes: 2 * 1024 * 1024,
        validateURL: { $0 == url }, timeout: .seconds(8),
        requestHeaders: [("User-Agent", "TheSocialWire/1.0 (+https://thesocialwire.app)"), ("Accept", "application/json")],
        requiredContentType: "application/json")
    } catch {
      // Provider diagnostics can include the query URL; never propagate them to server logs.
      throw PodcastDirectoryError.unavailable
    }
  }
}
