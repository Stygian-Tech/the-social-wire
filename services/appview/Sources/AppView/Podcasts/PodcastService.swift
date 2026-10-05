import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import NIOCore
import ThinAppViewCore

struct PodcastService: Sendable {
  let store: PostgresPodcastStore
  let http: HTTPClient
  let repo: ATProtoAuthenticatedRepoClient
  var bridgeEnabled: Bool { ProcessInfo.processInfo.environment["PODCAST_BRIDGE_ENABLED"] == "true" }
  func resolve(_ raw: String) async throws -> PodcastResolveResponse {
    if raw.hasPrefix("at://") {
      guard let parsed = RenderFieldExtractor.parseAtUri(raw),
        let collection = PodcastProtocolAdapter.collections[parsed.collection],
        let record = try await repo.getRecordByAtUri(auth: nil, atUri: raw)
      else { throw HTTPError(.badRequest, message: "Unsupported Podcast Source") }
      let base = try await ATProtoPdsResolution.resolvePdsBase(
        repoDid: parsed.did, plcBase: "https://plc.directory", httpClient: http)
      var show = try PodcastProtocolAdapter.show(uri: raw, record: record.values, blobBase: base)
      var episodes: [PodcastEpisode] = []
      var cursor: String?
      repeat {
        let page = try await repo.listRecords(
          auth: nil, repo: parsed.did, collection: collection, limit: 100, cursor: cursor,
          requireResolvedRepository: true)
        episodes += page.records.compactMap {
          PodcastProtocolAdapter.episode(
            uri: $0.uri, record: $0.value.values, show: show, blobBase: base)
        }
        cursor = page.cursor
      } while cursor != nil
      if let guid = show.guid, var existing = try await store.show(id: "guid:" + guid),
        existing.id != show.id
      {
        try await store.alias(show.id, canonical: existing.id, kind: "show")
        existing.sourceUri = show.sourceUri
        existing.episodeCollection = show.episodeCollection
        episodes = episodes.map {
          var episode = $0
          episode.showId = existing.id
          return episode
        }
        show = existing
      }
      episodes = await enrich(Array(episodes.prefix(50)), viewer: nil, persist: false) + Array(episodes.dropFirst(50))
      try await store.upsert(show: show, episodes: episodes)
      let aliases = try await store.canonicalEpisodeIDs(episodes.map(\.id))
      episodes = episodes.map {
        var episode = $0
        episode.id = aliases[episode.id] ?? episode.id
        return episode
      }
      return PodcastResolveResponse(show: show, episodes: episodes.map(visibleEpisode))
    }
    if raw.hasPrefix("did:")
      || (!raw.contains("/") && !raw.hasPrefix("https:") && !raw.hasPrefix("http:"))
    {
      var choices: [PodcastShow] = []
      for collection in PodcastProtocolAdapter.collections.keys.sorted() {
        var cursor: String?
        repeat {
          let page = try await repo.listRecords(
            auth: nil, repo: raw, collection: collection, limit: 100, cursor: cursor,
            requireResolvedRepository: true)
          choices += page.records.compactMap {
            try? PodcastProtocolAdapter.show(uri: $0.uri, record: $0.value.values)
          }
          cursor = page.cursor
        } while cursor != nil
      }
      guard let first = choices.first else {
        throw HTTPError(.notFound, message: "No Podcast Shows Found")
      }
      var resolved = try await resolve(first.sourceUri ?? first.id)
      resolved.shows = choices
      return resolved
    }
    guard PodcastRSSURL.isAllowed(raw), let url = RssFeedIdentity.normalizeFeedUrl(raw) else {
      throw HTTPError(.badRequest, message: "Only Public HTTPS Podcast Feeds Are Supported")
    }
    let body = try await PublicMediaFetcher.fetch(
      url: url, httpClient: http, maximumBytes: 32 * 1024 * 1024,
      validateURL: PodcastRSSURL.isAllowed)
    var result = try PodcastRSSParser(feedURL: url).parse(body)
    guard !result.episodes.isEmpty else {
      throw HTTPError(.badRequest, message: "No Audio Episodes Found")
    }
    var existing = try await store.show(id: url)
    if existing == nil, let guid = result.show.guid {
      existing = try await store.show(id: "guid:" + guid)
    }
    if let existing {
      result.show.id = existing.id
      result.show.guid = result.show.guid ?? existing.guid
      result.show.sourceUri = existing.sourceUri
      result.show.episodeCollection = existing.episodeCollection
      result.show.sourceKind = existing.sourceKind
      if result.show.hosts.isEmpty { result.show.hosts = existing.hosts }
      result.episodes = result.episodes.map {
        var episode = $0
        episode.showId = existing.id
        return episode
      }
    }
    result.episodes = await enrich(Array(result.episodes.prefix(50)), viewer: nil, persist: false) + Array(result.episodes.dropFirst(50))
    try await store.upsert(show: result.show, episodes: result.episodes)
    let aliases = try await store.canonicalEpisodeIDs(result.episodes.map(\.id))
    result.episodes = result.episodes.map {
      var episode = $0
      episode.id = aliases[episode.id] ?? episode.id
      return episode
    }
    return PodcastResolveResponse(show: result.show, episodes: result.episodes.map(visibleEpisode))
  }
  func hydrate(auth: AuthContext) async throws -> [PodcastShow] {
    var records: [(showID: String, uri: String)] = []
    var cursor: String?
    repeat {
      guard let page = try? await repo.listRecords(
        auth: nil, repo: auth.did, collection: "app.skyreader.feed.subscription", limit: 100,
        cursor: cursor, requireResolvedRepository: true)
      else { return try await store.shows(viewer: auth.did) + privateShows(viewer: auth.did) }
      for item in page.records {
        let value = item.value.values
        let source = value["externalRef"] as? String
        let feed = value["feedUrl"] as? String
        if let feed, !PodcastRSSURL.isAllowed(feed) { continue }
        let key = feed.flatMap(RssFeedIdentity.normalizeFeedUrl) ?? source
        guard let key else { continue }
        var show = try await store.show(id: key)
        if show == nil { show = try? await resolve(key).show }
        guard let show else { continue }
        if show.sourceKind == "rss", let feed = show.feedUrl, !PodcastRSSURL.isAllowed(feed) {
          continue
        }
        records.append((show.id, item.uri))
        if bridgeEnabled, show.sourceKind == "rss", let feed = show.feedUrl {
          let payload = try PodcastJSON.string(["showId": show.id, "feedUrl": feed])
          _ = try await store.enqueue(
            viewer: nil, episodeID: nil, kind: "bridge", key: "bridge:" + show.id, payload: payload)
        }
      }
      cursor = page.cursor
    } while cursor != nil
    try await store.subscriptions(viewer: auth.did, records: records)
    var shows = try await store.shows(viewer: auth.did)
    for index in shows.indices where bridgeEnabled {
      if let json = try await store.job(
        viewer: auth.did, jobID: nil, episodeID: nil, kind: "bridge", showID: shows[index].id),
        let status = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
      {
        shows[index].bridgeJobId = status["id"] as? String
        shows[index].bridgeStatus = status["status"] as? String
      }
    }
    return shows + (try await privateShows(viewer: auth.did))
  }
  func canonicalState(_ original: PodcastListenerState) async throws -> PodcastListenerState {
    var state = original
    state.normalizePlaybackSpeed()
    let aliases = try await store.canonicalEpisodeIDs(state.queue + Array(state.progress.keys))
      .merging(
        store.manualEpisodeAliases(links: state.manualLinks),
        uniquingKeysWith: { _, manual in manual })
    var seen = Set<String>()
    state.queue = state.queue.map { aliases[$0] ?? $0 }.filter { seen.insert($0).inserted }
    for (source, target) in aliases {
      if let value = state.progress.removeValue(forKey: source) {
        if let existing = state.progress[target],
          Self.progressDate(existing.updatedAt) > Self.progressDate(value.updatedAt)
        {
          continue
        }
        state.progress[target] = value
      }
    }
    return state
  }
  private static func progressDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? .distantPast
  }
  func transcripts(episode: PodcastEpisode) async throws -> [PodcastTranscript] {
    var result: [PodcastTranscript] = []
    for var transcript in episode.transcripts {
      do {
        let data = try await fetch(transcript.url, maxBytes: 8 * 1024 * 1024)
        let parsed = PodcastTranscriptParser.parse(data, type: transcript.type)
        transcript.text = parsed.text
        transcript.cues = parsed.cues
      } catch { transcript.cues = [] }
      result.append(transcript)
    }
    return result
  }
  func fingerprint(episode: PodcastEpisode) async throws -> String {
    let headers = try? await PublicMediaFetcher.fingerprint(url: episode.audioUrl, httpClient: http)
    let fallback =
      try PodcastJSON.encode(episode) + "|" + String(Int(Date().timeIntervalSince1970 / 900))
    return PodcastRSSParser.identity(headers ?? fallback)
  }
  func fetch(_ url: String, maxBytes: Int) async throws -> Data {
    guard RssFeedIdentity.isFetchableFeedUrl(url) else {
      throw HTTPError(.badRequest, message: "Invalid Public URL")
    }
    return try await PublicMediaFetcher.fetch(url: url, httpClient: http, maximumBytes: maxBytes)
  }
}
