import AsyncHTTPClient
import Foundation
import Logging

/// Scans a user's ATProto follow graph and discovers standard.site publications
/// for each followed account using the three-step discovery chain.
actor DiscoveryService {
  private let httpClient: HTTPClient
  private let cache: any CacheStore
  private let plcURL: String
  private let logger: Logger

  // Discovery chain steps, executed in order.
  private let chain: [any DiscoveryStep] = [
    LexiconNativeDiscovery(),
    ProfileLinkHeuristic(),
    DirectoryFallback(),
  ]

  // Track in-progress refresh jobs to avoid duplicate scans.
  private var activeRefreshes: Set<String> = []

  init(httpClient: HTTPClient, cache: any CacheStore, plcURL: String, logger: Logger) {
    self.httpClient = httpClient
    self.cache = cache
    self.plcURL = plcURL
    self.logger = logger
  }

  // MARK: - Public API

  /// Returns cached discovery results for the user.
  func cachedPublications(for userDID: String) async throws -> DiscoveryResponse {
    if let cached = try await cache.cachedPublications(for: userDID) {
      return DiscoveryResponse(publications: cached.publications, lastRefreshedAt: cached.lastRefreshedAt)
    }
    return DiscoveryResponse(publications: [], lastRefreshedAt: nil)
  }

  /// Triggers an async re-scan of the user's follow graph.
  /// Returns immediately; the scan runs in the background and updates the cache.
  func startRefresh(for userDID: String) async {
    guard !activeRefreshes.contains(userDID) else {
      logger.info("Discovery refresh already in progress", metadata: ["did": "\(userDID)"])
      return
    }
    activeRefreshes.insert(userDID)

    // Detach so the HTTP handler can return immediately
    let httpClient = self.httpClient
    let cache = self.cache
    let chain = self.chain
    let plcURL = self.plcURL
    let logger = self.logger

    Task.detached {
      defer {
        Task { await self.finishRefresh(for: userDID) }
      }
      do {
        try await Self.runDiscovery(
          userDID: userDID,
          httpClient: httpClient,
          cache: cache,
          chain: chain,
          plcURL: plcURL,
          logger: logger
        )
      } catch {
        logger.error("Discovery refresh failed", metadata: ["did": "\(userDID)", "error": "\(error)"])
      }
    }
  }

  private func finishRefresh(for userDID: String) {
    activeRefreshes.remove(userDID)
  }

  // MARK: - Discovery logic (nonisolated, runs on detached Task)

  private static func runDiscovery(
    userDID: String,
    httpClient: HTTPClient,
    cache: any CacheStore,
    chain: [any DiscoveryStep],
    plcURL: String,
    logger: Logger
  ) async throws {
    logger.info("Starting discovery for user", metadata: ["did": "\(userDID)"])

    let followedDIDs = try await fetchFollowGraph(userDID: userDID, httpClient: httpClient, logger: logger)
    logger.info("Found \(followedDIDs.count) followed accounts", metadata: ["did": "\(userDID)"])

    // Run discovery chain concurrently across all followed DIDs
    let publications = try await withThrowingTaskGroup(of: DiscoveredPublication?.self) { group in
      for followedDID in followedDIDs {
        group.addTask {
          return try await runChain(
            for: followedDID,
            chain: chain,
            plcURL: plcURL,
            httpClient: httpClient,
            logger: logger
          )
        }
      }

      var results: [DiscoveredPublication] = []
      for try await pub in group {
        if let pub { results.append(pub) }
      }
      return results
    }

    logger.info("Discovered \(publications.count) publications", metadata: ["did": "\(userDID)"])
    try await cache.storePublications(publications, for: userDID)
  }

  /// Fetches the list of DIDs that `userDID` follows via the Bluesky AppView.
  private static func fetchFollowGraph(
    userDID: String,
    httpClient: HTTPClient,
    logger: Logger
  ) async throws -> [String] {
    var allDIDs: [String] = []
    var cursor: String? = nil

    repeat {
      var urlComponents = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.graph.getFollows")!
      var queryItems = [URLQueryItem(name: "actor", value: userDID), URLQueryItem(name: "limit", value: "100")]
      if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
      urlComponents.queryItems = queryItems

      var request = HTTPClientRequest(url: urlComponents.url!.absoluteString)
      request.headers.add(name: "Accept", value: "application/json")

      let response = try await httpClient.execute(request, timeout: .seconds(15))
      guard response.status == .ok else {
        logger.warning("Failed to fetch follow graph", metadata: ["did": "\(userDID)", "status": "\(response.status)"])
        break
      }

      let body = try await response.body.collect(upTo: 256 * 1024)
      guard let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any] else { break }

      let follows = (json["follows"] as? [[String: Any]]) ?? []
      allDIDs.append(contentsOf: follows.compactMap { $0["did"] as? String })
      cursor = json["cursor"] as? String
    } while cursor != nil

    return allDIDs
  }

  /// Runs the discovery chain for a single DID, stopping at the first successful step.
  private static func runChain(
    for did: String,
    chain: [any DiscoveryStep],
    plcURL: String,
    httpClient: HTTPClient,
    logger: Logger
  ) async throws -> DiscoveredPublication? {
    for step in chain {
      do {
        if let pub = try await step.discover(authorDID: did, plcURL: plcURL, httpClient: httpClient) {
          logger.debug("Discovered via \(step.name)", metadata: ["did": "\(did)", "pub": "\(pub.publicationId)"])
          return pub
        }
      } catch {
        // Log and try the next step
        logger.debug("Discovery step \(step.name) failed", metadata: ["did": "\(did)", "error": "\(error)"])
      }
    }
    return nil
  }
}
