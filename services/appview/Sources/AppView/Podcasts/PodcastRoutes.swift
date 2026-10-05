import Foundation
import GatewayCore
import Hummingbird
import ThinAppViewCore

struct PodcastRoutes {
  let service: PodcastService
  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.post("/v1/podcasts/search") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let input = try await request.decode(as: PodcastSearchRequest.self, context: context)
      do {
        let result = try await service.store.search(viewer: auth.did, request: input)
        var response = PodcastJSON.response(try PodcastJSON.encode(result))
        response.headers[.cacheControl] = "private, no-store"
        return response
      } catch PodcastStoreError.invalidRequest {
        throw HTTPError(.badRequest, message: "Invalid Podcast Search")
      }
    }
    group.post("/v1/podcasts/resolve") { request, context async throws -> PodcastResolveResponse in
      guard context.authContext != nil else { throw HTTPError(.unauthorized) }
      return try await service.resolve(
        request.decode(as: PodcastResolveRequest.self, context: context).url)
    }
    group.get("/v1/podcasts/shows") { _, context async throws -> [String: [PodcastShow]] in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let shows = try await service.hydrate(auth: auth)
      let snapshot = try await service.store.state(viewer: auth.did)
      let hidden = Set(snapshot.state.manualLinks.map(\.protocolShowId))
      return ["shows": shows.filter { !hidden.contains($0.id) }]
    }
    group.get("/v1/podcasts/episodes") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      if let id = request.uri.queryParameters.get("episodeId") {
        guard let episode = try await service.episode(id: id, viewer: auth.did) else { throw HTTPError(.notFound) }
        return try Self.episodesResponse(await service.enrich([episode], viewer: auth.did).map(service.visibleEpisode), limit: 2)
      }
      let limit = max(1, min(Int(request.uri.queryParameters.get("limit") ?? "50") ?? 50, 100))
      let cursor = request.uri.queryParameters.get("cursor")
      if request.uri.queryParameters.get("queue") == "true" {
        let items = try await service.store.queuedEpisodes(viewer: auth.did)
        return try Self.episodesResponse(await service.enrich(items, viewer: auth.did).map(service.visibleEpisode), limit: Int.max)
      }
      if request.uri.queryParameters.get("showId") == nil {
        let items = try await service.store.subscribedEpisodes(viewer: auth.did, cursor: cursor, limit: limit)
        return try Self.episodesResponse(await service.enrich(items, viewer: auth.did).map(service.visibleEpisode), limit: limit)
      }
      if let id = request.uri.queryParameters.get("showId"), PodcastPrivateCatalog.isPrivateID(id) {
        guard try await service.store.privateShow(viewer: auth.did, id: id) != nil else { throw HTTPError(.notFound) }
        let items = try await service.store.privateEpisodes(viewer: auth.did, showID: id, cursor: cursor, limit: limit)
        return try Self.episodesResponse(await service.enrich(items, viewer: auth.did).map(service.visibleEpisode), limit: limit)
      }
      guard let showID = request.uri.queryParameters.get("showId"),
        let show = try await service.store.show(id: showID)
      else { throw HTTPError(.notFound) }
      var items = try await service.store.episodes(
        showID: show.id, cursor: request.uri.queryParameters.get("cursor"), limit: limit)
      if let auth = context.authContext {
        let snapshot = try await service.store.state(viewer: auth.did)
        let links = snapshot.state.manualLinks.filter { $0.rssShowId == show.id }
        for link in links {
          items += try await service.store.episodes(
            showID: link.protocolShowId, cursor: request.uri.queryParameters.get("cursor"),
            limit: limit)
        }
        let aliases = try await service.store.manualEpisodeAliases(links: links)
        items = items.map {
          var episode = $0
          episode.id = aliases[episode.id] ?? episode.id
          return episode
        }
        var seen = Set<String>()
        items = items.sorted {
          $0.publishedAt == $1.publishedAt ? $0.id > $1.id : $0.publishedAt > $1.publishedAt
        }.filter { seen.insert($0.guid ?? $0.id).inserted }
        items = Array(items.prefix(limit))
      }
      items = await service.enrich(items, viewer: auth.did)
      let encoded = try JSONEncoder().encode(items.map(service.visibleEpisode))
      var body = "{\"episodes\":" + String(decoding: encoded, as: UTF8.self)
      if items.count == limit, let last = items.last {
        body += ",\"cursor\":" + (try PodcastJSON.encode(last.id))
      }
      body += "}"
      return PodcastJSON.response(body)
    }
    group.get("/v1/podcasts/state") { _, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let shows = try await service.hydrate(auth: auth)
      var snapshot = try await service.store.state(viewer: auth.did)
      snapshot.state.subscriptions = shows.map(\.id)
      snapshot.state = try await service.canonicalState(snapshot.state)
      return PodcastJSON.response(try PodcastJSON.encode(snapshot))
    }
    group.put("/v1/podcasts/state") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      var body = try await request.decode(as: PodcastStateRequest.self, context: context)
      guard body.state.validate() else {
        throw HTTPError(.badRequest, message: "Invalid Podcast State")
      }
      body.state.subscriptions = try await service.store.shows(viewer: auth.did).map(\.id)
        + service.store.privateShows(viewer: auth.did).map(\.id)
      // Linking remains viewer-private and requires opposite source types.
      for link in body.state.manualLinks {
        guard let rss = try await service.store.show(id: link.rssShowId), rss.sourceKind == "rss",
          let protocolShow = try await service.store.show(id: link.protocolShowId),
          protocolShow.sourceKind == "atproto"
        else { throw HTTPError(.badRequest, message: "Invalid Podcast Link") }
      }
      body.state = try await service.canonicalState(body.state)
      do {
        return PodcastJSON.response(
          try PodcastJSON.encode(
            await service.store.saveState(
              viewer: auth.did, expected: body.expectedRevision, state: body.state)))
      } catch PodcastStoreError.revisionConflict {
        throw HTTPError(.conflict, message: "Podcast State Revision Conflict")
      } catch PodcastStoreError.invalidState {
        throw HTTPError(.badRequest, message: "Invalid Podcast State")
      }
    }
    group.get("/v1/podcasts/transcript") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      guard let id = request.uri.queryParameters.get("episodeId"),
        let episode = try await service.episode(id: id, viewer: auth.did)
      else { throw HTTPError(.notFound) }
      let transcripts = try await service.transcripts(episode: episode).map { original in
        var transcript = original
        if episode.visibility == "private" {
          transcript.url = ""
          transcript.text = transcript.text.map(PodcastPrivateCatalog.visibleText)
          transcript.cues = (transcript.cues ?? []).map { original in
            var cue = original
            cue.text = PodcastPrivateCatalog.visibleText(cue.text)
            return cue
          }
        }
        return transcript
      }
      return PodcastJSON.response(
        "{\"episodeId\":" + (try PodcastJSON.encode(id)) + ",\"transcripts\":"
          + (try PodcastJSON.encode(transcripts)) + "}")
    }
    group.post("/v1/podcasts/analysis") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: PodcastEpisodeRequest.self, context: context)
      guard let episode = try await service.episode(id: body.episodeId, viewer: auth.did) else {
        throw HTTPError(.notFound)
      }
      guard episode.visibility != "private" else { throw HTTPError(.forbidden, message: "Silence Analysis Is Unavailable For Private Podcasts") }
      let fingerprint = try await service.fingerprint(episode: episode)
      let payload = try PodcastJSON.encode(
        PodcastJobPayload(episode: episode, sourceFingerprint: fingerprint))
      let id = try await service.store.enqueue(
        viewer: nil, episodeID: episode.id, kind: "silence",
        key: "silence:v2:" + episode.id + ":" + fingerprint,
        payload: payload)
      _ = try await service.store.retry(viewer: auth.did, id: id)
      guard
        let job = try await service.store.job(
          viewer: auth.did, jobID: id, episodeID: nil, kind: "silence")
      else { throw HTTPError(.notFound) }
      return PodcastJSON.response(job)
    }
    group.get("/v1/podcasts/analysis") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      guard let id = request.uri.queryParameters.get("episodeId"),
        let episode = try await service.episode(id: id, viewer: auth.did)
      else { throw HTTPError(.badRequest) }
      if episode.visibility == "private" {
        return PodcastJSON.response("{\"analysisVersion\":\"v2\",\"status\":\"unavailable\",\"reason\":\"private-feed\",\"intervals\":[]}")
      }
      let expectedFingerprint = try await service.fingerprint(episode: episode)
      let analysisKey = "silence:v2:" + id + ":" + expectedFingerprint
      guard
        let raw = try await service.store.job(
          viewer: auth.did, jobID: nil, episodeID: id, kind: "silence", key: analysisKey),
        let job = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
      else { return PodcastJSON.response("{\"analysisVersion\":\"v2\",\"status\":\"unavailable\",\"intervals\":[]}") }
      let result = job["result"] as? [String: Any] ?? [:]
      if job["status"] as? String == "complete",
        result["sourceFingerprint"] as? String != expectedFingerprint
      {
        if let jobID = job["id"] as? String {
          try await service.store.invalidateAnalysis(id: jobID, fingerprint: expectedFingerprint)
        }
        return PodcastJSON.response("{\"analysisVersion\":\"v2\",\"status\":\"unavailable\",\"intervals\":[]}")
      }
      return PodcastJSON.response(
        String(
          decoding: try JSONSerialization.data(withJSONObject: [
            "analysisVersion": "v2", "status": job["status"] ?? "unavailable", "intervals": result["intervals"] ?? [],
          ]), as: UTF8.self))
    }
    group.get("/v1/podcasts/jobs") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let id = request.uri.queryParameters.get("jobId")
      let showID = request.uri.queryParameters.get("showId")
      let clipID = request.uri.queryParameters.get("clipId")
      guard id != nil || showID != nil || clipID != nil,
        let raw = try await service.store.job(
          viewer: auth.did, jobID: id, episodeID: nil,
          kind: showID != nil ? "bridge" : (clipID != nil ? "clip" : nil),
          showID: showID, clipID: clipID)
      else { throw HTTPError(.notFound) }
      return PodcastJSON.response(raw)
    }
    group.post("/v1/podcasts/jobs") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: PodcastJobRetryRequest.self, context: context)
      guard try await service.store.retry(viewer: auth.did, id: body.jobId) else {
        throw HTTPError(.conflict, message: "Job Cannot Be Retried")
      }
      guard
        let job = try await service.store.job(
          viewer: auth.did, jobID: body.jobId, episodeID: nil, kind: nil)
      else { throw HTTPError(.notFound) }
      return PodcastJSON.response(job)
    }
    group.post("/v1/podcasts/clips") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: PodcastClipRequest.self, context: context)
      if PodcastPrivateCatalog.isPrivateID(body.episodeId) {
        guard try await service.store.privateEpisode(viewer: auth.did, id: body.episodeId) != nil else { throw HTTPError(.notFound) }
        throw HTTPError(.forbidden, message: "Clipping Private Podcasts Is Not Supported")
      }
      guard var episode = try await service.store.episode(id: body.episodeId),
        let show = try await service.store.show(id: episode.showId), body.startSeconds.isFinite,
        body.endSeconds.isFinite, body.startSeconds >= 0, body.endSeconds > body.startSeconds,
        body.endSeconds - body.startSeconds <= 600, body.endSeconds * 1000 < Double(Int.max),
        episode.durationSeconds.map({ body.endSeconds <= $0 }) ?? true
      else { throw HTTPError(.badRequest, message: "Invalid Clip Range") }
      episode.transcripts =
        body.includeCaptions == false ? [] : try await service.transcripts(episode: episode)
      var clip = PodcastClip(
        id: UUID().uuidString.lowercased(), episodeId: episode.id, startSeconds: body.startSeconds,
        endSeconds: body.endSeconds, title: body.title ?? episode.title,
        createdAt: ISO8601DateFormatter().string(from: Date()))
      clip.sourceUri = episode.sourceUri
      let payload = try PodcastJSON.encode(
        PodcastJobPayload(
          episode: episode, show: show, clipId: clip.id, startSeconds: clip.startSeconds,
          endSeconds: clip.endSeconds, title: clip.title))
      let job = try await service.store.prepareClip(viewer: auth.did, clip: clip, payload: payload)
      return PodcastJSON.response(
        try PodcastJSON.string(["clipId": clip.id, "jobId": job, "status": "queued"]))
    }
    group.get("/v1/podcasts/clips") { _, context async throws -> [String: [PodcastClip]] in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      return ["clips": try await service.store.clips(viewer: auth.did)]
    }
    group.post("/v1/podcasts/clips/publish") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: PodcastPublishRequest.self, context: context)
      guard let clip = try await service.store.clip(id: body.clipId, viewer: auth.did),
        clip.status == "complete", let parsed = RenderFieldExtractor.parseAtUri(body.uri),
        parsed.did == auth.did, parsed.collection == "app.thesocialwire.podcast.clip",
        let record = try await service.repo.getRecordByAtUri(auth: nil, atUri: body.uri)
      else { throw HTTPError(.badRequest, message: "Clip Record Unavailable") }
      guard Self.matches(record.values, clip: clip) else {
        throw HTTPError(.badRequest, message: "Clip Record Does Not Match Rendered Clip")
      }
      try await service.store.publishClip(id: clip.id, viewer: auth.did, uri: body.uri)
      return PodcastJSON.response(try PodcastJSON.string(["clipId": clip.id, "uri": body.uri]))
    }
    group.delete("/v1/podcasts/clips") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      guard let id = request.uri.queryParameters.get("clipId"),
        let clip = try await service.store.clip(id: id, viewer: auth.did)
      else { throw HTTPError(.notFound) }
      let payload = try PodcastJSON.string([
        "clipId": clip.id, "audioKey": clip.audioKey ?? "clips/" + clip.id + "/audio.m4a",
        "videoKey": clip.videoKey ?? "clips/" + clip.id + "/audiogram.mp4",
      ])
      try await service.store.removeClip(viewer: auth.did, clip: clip, payload: payload)
      return PodcastJSON.response("{}")
    }
  }
  private static func episodesResponse(_ items: [PodcastEpisode], limit: Int) throws -> Response {
    var body = "{\"episodes\":" + (try PodcastJSON.encode(items))
    if items.count == limit, let last = items.last { body += ",\"cursor\":" + (try PodcastJSON.encode(last.id)) }
    return PodcastJSON.response(body + "}")
  }
  static func matches(_ record: [String: Any], clip: PodcastClip) -> Bool {
    record["$type"] as? String == "app.thesocialwire.podcast.clip"
      && record["episodeId"] as? String == clip.episodeId
      && record["startMillis"] as? Int == Int((clip.startSeconds * 1000).rounded())
      && record["endMillis"] as? Int == Int((clip.endSeconds * 1000).rounded())
      && record["audioUrl"] as? String == clip.publicAudioUrl
      && record["videoUrl"] as? String == clip.publicVideoUrl
  }
  func registerPublic(on router: Router<GatewayRequestContext>) {
    router.get("/v1/podcasts/public/clips") { request, _ async throws -> Response in
      guard
        let id = request.uri.queryParameters.get("clipId")
          ?? request.uri.queryParameters.get("uri"),
        let clip = try await service.store.clip(id: id, viewer: nil, publishedOnly: true)
      else { throw HTTPError(.notFound) }
      // Publication is verified live, so deleting the PDS clip immediately removes its public embed.
      guard let uri = clip.publishedUri,
        let record = try await service.repo.getRecordByAtUri(auth: nil, atUri: uri),
        Self.matches(record.values, clip: clip)
      else { throw HTTPError(.notFound) }
      return PodcastJSON.response(try PodcastJSON.encode(clip))
    }
  }
}
