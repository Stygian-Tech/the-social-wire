import Crypto
import Foundation
import ThinAppViewCore

/// Process-local public-result cache. Self-imposed provider budget: 20 misses/minute, two requests.
actor PodcastDirectorySearch {
  static let shared = PodcastDirectorySearch()
  private struct Cached {
    let expires: Date
    let candidates: [PodcastDirectoryCandidate]
  }
  private var cache: [String: Cached] = [:]
  private var pending: [String: Task<[PodcastDirectoryCandidate], any Error>] = [:]
  private var requests: [Date] = []
  private let now: @Sendable () -> Date
  private let maximumRequests: Int
  private let maximumConcurrent: Int
  init(now: @escaping @Sendable () -> Date = Date.init, maximumRequests: Int = 20, maximumConcurrent: Int = 2) {
    self.now = now
    self.maximumRequests = maximumRequests
    self.maximumConcurrent = maximumConcurrent
  }
  func search(_ input: PodcastSearchRequest, fetch: @escaping @Sendable (String) async throws -> Data) async throws -> PodcastSearchResponse {
    let query = try PodcastDirectoryQuery.validate(input)
    let key = SHA256.hash(data: Data(query.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    let time = now()
    cache = cache.filter { $0.value.expires > time }
    if let cached = cache[key] { return result(cached.candidates, limit: input.limit ?? 50) }
    if let task = pending[key] {
      do { return result(try await task.value, limit: input.limit ?? 50) }
      catch { throw PodcastDirectoryError.unavailable }
    }
    requests.removeAll { time.timeIntervalSince($0) >= 60 }
    guard requests.count < maximumRequests, pending.count < maximumConcurrent else { throw PodcastDirectoryError.busy }
    requests.append(time)
    let task = Task { try PodcastDirectoryParser.parse(await fetch(query)) }
    pending[key] = task
    defer { pending.removeValue(forKey: key) }
    let candidates: [PodcastDirectoryCandidate]
    do { candidates = try await task.value } catch { throw PodcastDirectoryError.unavailable }
    if cache.count >= 128, let oldest = cache.min(by: { $0.value.expires < $1.value.expires })?.key { cache.removeValue(forKey: oldest) }
    cache[key] = Cached(expires: now().addingTimeInterval(300), candidates: candidates)
    return result(candidates, limit: input.limit ?? 50)
  }
  private func result(_ candidates: [PodcastDirectoryCandidate], limit: Int) -> PodcastSearchResponse {
    var response = PodcastSearchResponse()
    response.candidates = Array(candidates.prefix(min(limit, 50)))
    response.directoryLimit = 50
    return response
  }
}
