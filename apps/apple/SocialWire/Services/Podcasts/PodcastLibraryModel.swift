import Foundation
import Observation

@MainActor
@Observable
final class PodcastLibraryModel {
    private(set) var resolvedShows: [PodcastShow] = []
    private(set) var showEpisodes: [String: [PodcastEpisode]] = [:]
    private(set) var queueEpisodes: [PodcastEpisode] = []
    private(set) var resolvedShow: PodcastShow?
    @ObservationIgnored private var selectedShowId: String?
    private(set) var available = false
    private(set) var shows: [PodcastShow] = []
    private(set) var recentEpisodes: [PodcastEpisode] = []
    private(set) var preparingEpisodeID: String?
    private(set) var episodes: [PodcastEpisode] = []
    private(set) var clips: [PodcastClip] = []
    private(set) var transcript: [PodcastTranscript] = []
    private(set) var state = PodcastListenerState()
    private(set) var loading = false
    private(set) var preparingClip = false
    private(set) var processingSilence = false
    private(set) var bridgeStatus: [String: String] = [:]
    private(set) var bridgeErrors: [String: String] = [:]
    @ObservationIgnored private var bridgeJobIDs: [String: String] = [:]
    private(set) var clipStatus: String?
    var error: String?
    let player = PodcastPlaybackController()
    let downloads = PodcastDownloadStore()
    @ObservationIgnored private let gateway: SocialWireGatewayClient
    @ObservationIgnored private let xrpc: XRPCClient
    @ObservationIgnored private var viewer: String?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var exportFiles: [URL] = []
    @ObservationIgnored private var pendingProgress: [String: PodcastProgress] = [:]

    init(gateway: SocialWireGatewayClient, xrpc: XRPCClient) {
        self.gateway = gateway
        self.xrpc = xrpc
        downloads.onCompletion = { [weak self] episode in
            guard let self, self.preparingEpisodeID == episode.id else { return }
            self.preparingEpisodeID = nil
            Task { await self.play(episode) }
        }
        downloads.onAuthenticationChallenge = { [weak self] episode, response in
            guard let self, let viewer = self.viewer else { throw SocialWireError.invalidURL }
            return try await self.gateway.podcastDownloadRequest(media: episode.audioURL, expectedViewer: viewer, challenge: response)
        }
        player.onProgress = { [weak self] id, position, completed in
            self?.reportProgress(id: id, position: position, completed: completed)
            if completed { Task { [weak self] in await self?.advanceQueue(after: id) } }
        }
    }

    func configure(viewer: String?) async {
        if self.viewer != viewer {
            self.viewer = nil
            for file in exportFiles { try? FileManager.default.removeItem(at: file) }
            exportFiles = []
            progressTask?.cancel()
            progressTask = nil
            analysisTask?.cancel()
            analysisTask = nil
            pendingProgress = [:]
            player.reset()
            self.viewer = viewer
            error = nil
            downloads.configure(viewer: viewer)
            if let viewer, let data = UserDefaults.standard.data(forKey: "podcast-pending-progress.\(PodcastDownloadStore.key(viewer))") {
                pendingProgress = (try? JSONDecoder().decode([String: PodcastProgress].self, from: data)) ?? [:]
            }
            resolvedShow = nil
            resolvedShows = []
            showEpisodes = [:]
            queueEpisodes = []
            selectedShowId = nil
            clipStatus = nil
            preparingClip = false
            processingSilence = false
            shows = []
            recentEpisodes = []
            preparingEpisodeID = nil
            episodes = []
            clips = []
            transcript = []
            state = PodcastListenerState()
            bridgeStatus = [:]
            bridgeErrors = [:]
            bridgeJobIDs = [:]
            available = false
            revision = 0
        }
        guard let viewer else { return }
        do {
            let result: ShowsResponse = try await request(path: "/v1/podcasts/shows", viewer: viewer)
            guard self.viewer == viewer else { return }
            available = true
            UserDefaults.standard.set(true, forKey: "podcast-available.\(PodcastDownloadStore.key(viewer))")
            shows = result.shows
            try await refreshState(viewer: viewer)
            if let (id, value) = pendingProgress.first { reportProgress(id: id, position: value.positionSeconds, completed: value.completed) }
        } catch {
            guard self.viewer == viewer else { return }
            if (error as? PodcastGatewayFailure)?.status == 404 {
                available = false
                UserDefaults.standard.set(false, forKey: "podcast-available.\(PodcastDownloadStore.key(viewer))")
            } else {
                available = UserDefaults.standard.bool(forKey: "podcast-available.\(PodcastDownloadStore.key(viewer))")
                self.error = error.localizedDescription
            }
        }
    }

    func refresh() async {
        guard let viewer else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result: ShowsResponse = try await request(path: "/v1/podcasts/shows", viewer: viewer)
            guard self.viewer == viewer else { return }
            shows = result.shows
            try await refreshState(viewer: viewer)
            let clipResult: ClipsResponse = try await request(path: "/v1/podcasts/clips", viewer: viewer)
            guard self.viewer == viewer else { return }
            clips = clipResult.clips
            await loadRecentEpisodes()
        } catch { self.error = error.localizedDescription }
    }

    func resolve(_ url: String, privateFeed: Bool = false) async {
        guard let viewer else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response: ResolveResponse = try await request(method: "POST", path: privateFeed ? "/v1/podcasts/private/resolve" : "/v1/podcasts/resolve", body: ["url": url], viewer: viewer)
            guard self.viewer == viewer else { return }
            resolvedShow = response.show
            resolvedShows = response.shows ?? [response.show]
            showEpisodes[response.show.id] = response.episodes
            selectedShowId = response.show.id
            shows.removeAll { $0.id == response.show.id }
            shows.append(response.show)
            for show in response.shows ?? [] where !shows.contains(where: { $0.id == show.id }) { shows.append(show) }
            episodes = response.episodes
            if privateFeed { try await refreshState(viewer: viewer) }
            else { await refreshBridgeStatus(showId: response.show.id) }
        } catch { self.error = error.localizedDescription }
    }

    func loadEpisodes(show: PodcastShow) async {
        guard let viewer else { return }
        selectedShowId = show.id
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response: EpisodesResponse = try await request(path: "/v1/podcasts/episodes", query: ["showId": show.id, "limit": "100"], viewer: viewer)
            guard self.viewer == viewer else { return }
            showEpisodes[show.id] = response.episodes
            guard selectedShowId == show.id else { return }
            episodes = response.episodes
            if !show.isPrivate { await refreshBridgeStatus(showId: show.id) }
        } catch { self.error = error.localizedDescription }
    }

    func play(_ episode: PodcastEpisode) async {
        if episode.isPrivate, downloads.localURL(episode.id) == nil {
            player.pause()
            preparingEpisodeID = episode.id
            await download(episode)
            return
        }
        preparingEpisodeID = nil
        player.load(episode, localURL: downloads.localURL(episode.id), resume: state.progress[episode.id]?.positionSeconds ?? 0, showTitle: shows.first(where: { $0.id == episode.showId })?.title)
        transcript = []
        guard let viewer else { return }
        do {
            let result: TranscriptResponse = try await request(path: "/v1/podcasts/transcript", query: ["episodeId": episode.id], viewer: viewer)
            guard self.viewer == viewer, player.episode?.id == episode.id else { return }
            transcript = result.transcripts
        } catch { self.error = error.localizedDescription }
        if player.removesSilence, episode.permitsPublicProcessing { await requestSilence() }
    }

    var knownEpisodes: [String: PodcastEpisode] {
        var result = downloads.episodes
        for episode in recentEpisodes + episodes + queueEpisodes + showEpisodes.values.flatMap({ $0 }) { result[episode.id] = episode }
        return result
    }

    var downloadedEpisodes: [PodcastEpisode] {
        downloads.downloadedIDs.compactMap { knownEpisodes[$0] }.sorted { $0.publishedAt > $1.publishedAt }
    }

    var queuedEpisodes: [PodcastEpisode] { state.queue.compactMap { knownEpisodes[$0] } }

    func loadRecentEpisodes() async {
        guard let viewer else { return }
        do {
            let response: EpisodesResponse = try await request(path: "/v1/podcasts/episodes", query: ["limit": "50"], viewer: viewer)
            guard self.viewer == viewer else { return }
            recentEpisodes = response.episodes
        } catch { self.error = error.localizedDescription }
    }

    func loadQueueEpisodes() async {
        guard let viewer else { return }
        do {
            let response: EpisodesResponse = try await request(path: "/v1/podcasts/episodes", query: ["queue": "true", "limit": "100"], viewer: viewer)
            guard self.viewer == viewer else { return }
            queueEpisodes = response.episodes
        } catch { self.error = error.localizedDescription }
    }

    func download(_ episode: PodcastEpisode) async {
        guard let viewer else { return }
        do {
            if episode.isPrivate {
                let request = try await gateway.podcastDownloadRequest(media: episode.audioURL, expectedViewer: viewer)
                guard self.viewer == viewer else { return }
                downloads.download(episode, request: request)
            } else { downloads.download(episode) }
        } catch {
            preparingEpisodeID = nil
            self.error = "Could Not Prepare Download. Sign In Again or Retry."
        }
    }

    func cancelDownload(_ id: String) {
        if preparingEpisodeID == id { preparingEpisodeID = nil }
        downloads.cancel(id)
    }

    func refreshPrivateShow(_ show: PodcastShow) async {
        guard show.isPrivate, let viewer else { return }
        do {
            let response: ResolveResponse = try await request(method: "POST", path: "/v1/podcasts/private/refresh", body: ["showId": show.id], viewer: viewer)
            guard self.viewer == viewer else { return }
            shows.removeAll { $0.id == show.id }
            shows.append(response.show)
            episodes = response.episodes
            showEpisodes[show.id] = response.episodes
            await loadRecentEpisodes()
        } catch { self.error = "Could Not Refresh Private Feed. Retry Later." }
    }

    func enqueue(_ episode: PodcastEpisode) async {
        await mutateState { state in
            if !state.queue.contains(episode.id) { state.queue.append(episode.id) }
        }
    }

    func removeFromQueue(_ id: String) async { await mutateState { $0.queue.removeAll { $0 == id } } }

    func setSpeed(_ speed: Double) async {
        guard (0.5...3).contains(speed), (speed * 4).rounded() == speed * 4 else { return }
        player.speed = speed
        await mutateState { $0.playbackSpeed = speed }
    }

    func setRemoveSilences(_ value: Bool) async {
        player.removesSilence = value
        await mutateState { $0.removeSilences = value }
        if value { await requestSilence() }
        else { analysisTask?.cancel(); processingSilence = false }
    }

    func requestSilence() async {
        guard let episode = player.episode, let viewer else { return }
        guard episode.permitsPublicProcessing else {
            processingSilence = false
            error = "Silence Analysis Is Unavailable for Private Episodes."
            return
        }
        analysisTask?.cancel()
        processingSilence = true
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let _: JobResponse = try await self.request(method: "POST", path: "/v1/podcasts/analysis", body: ["episodeId": episode.id], viewer: viewer)
                for _ in 0..<120 {
                    try Task.checkCancellation()
                    let result: AnalysisResponse = try await self.request(path: "/v1/podcasts/analysis", query: ["episodeId": episode.id], viewer: viewer)
                    guard self.viewer == viewer, self.player.episode?.id == episode.id else { return }
                    if result.status == "ready" || result.status == "completed" || result.status == "complete" {
                        self.player.silenceIntervals = result.intervals ?? []
                        self.processingSilence = false
                        return
                    }
                    if result.status == "failed" { throw SocialWireError.badResponse("Silence Analysis Failed. Try Again.") }
                    try await Task.sleep(for: .seconds(3))
                }
                throw SocialWireError.badResponse("Silence Analysis Is Still Processing. Try Again Later.")
            } catch is CancellationError {} catch {
                self.error = error.localizedDescription
                self.processingSilence = false
            }
        }
    }

    func toggleSubscription(_ show: PodcastShow) async {
        guard let viewer else { return }
        if show.isPrivate {
            do {
                let _: JSONValue = try await request(method: "DELETE", path: "/v1/podcasts/private/subscriptions", query: ["showId": show.id], viewer: viewer)
                await refresh()
            } catch { self.error = "Could Not Remove Private Subscription. Try Again." }
            return
        }
        if let feed = show.feedUrl, !PodcastPrivacy.permitsPublicURL(feed) {
            error = "Add This Feed as Private RSS to Keep Its Credentials Private."
            return
        }
        do {
            let collection = "app.skyreader.feed.subscription"
            var cursor: String?
            var existing: [GenericRepoRecord] = []
            repeat {
                let page = try await xrpc.listAuthorizedGenericRecords(collection: collection, cursor: cursor)
                existing += page.records.filter { record in
                    record.value.object?["feedUrl"]?.string == show.feedUrl && show.feedUrl != nil
                        || record.value.object?["externalRef"]?.string == show.sourceUri && show.sourceUri != nil
                }
                cursor = page.cursor
            } while cursor != nil
            guard self.viewer == viewer else { return }
            if state.subscriptions.contains(show.id) {
                for record in existing { try await xrpc.deleteRecord(collection: collection, rkey: rkey(from: record.uri), expectedViewer: viewer) }
            } else if existing.isEmpty {
                var record: [String: JSONValue] = ["$type": .string(collection), "title": .string(show.title),
                    "source": .string("the-social-wire"), "createdAt": .string(DateFormatters.string())]
                if let feed = show.feedUrl {
                    record["feedUrl"] = .string(feed)
                    record["sourceType"] = .string("rss")
                    if let uri = show.sourceUri { record["externalRef"] = .string(uri) }
                } else if let uri = show.sourceUri, let at = ATURI(uri),
                          let episodeCollection = show.episodeCollection {
                    record["sourceType"] = .string("atproto.collection")
                    record["subjectDid"] = .string(at.repo)
                    record["collectionNsid"] = .string(episodeCollection)
                    record["externalRef"] = .string(uri)
                } else { throw SocialWireError.badResponse("This Podcast Does Not Have a Supported Subscription Source") }
                try await xrpc.putRecord(collection: collection, rkey: PodcastDownloadStore.key(show.id), record: record, expectedViewer: viewer)
            }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func refreshBridgeStatus(showId: String) async {
        guard let viewer else { return }
        do {
            let job: ClipJobResponse = try await request(path: "/v1/podcasts/jobs", query: ["showId": showId], viewer: viewer)
            guard self.viewer == viewer else { return }
            bridgeStatus[showId] = job.status
            bridgeErrors[showId] = job.error
            bridgeJobIDs[showId] = job.id
        } catch let error as PodcastGatewayFailure where error.status == 404 {} catch { self.error = error.localizedDescription }
    }

    func retryBridge(showId: String) async {
        guard let viewer, let id = bridgeJobIDs[showId] else { return }
        do {
            let _: JobResponse = try await request(method: "POST", path: "/v1/podcasts/jobs", body: ["jobId": id], viewer: viewer)
            await refreshBridgeStatus(showId: showId)
        } catch { self.error = error.localizedDescription }
    }

    func sync() async {
        guard let viewer else { return }
        do {
            try await refreshState(viewer: viewer)
            if let (id, value) = pendingProgress.first { reportProgress(id: id, position: value.positionSeconds, completed: value.completed) }
        } catch { self.error = error.localizedDescription }
    }

    private func advanceQueue(after id: String) async {
        await removeFromQueue(id)
        if let next = state.queue.first { await playQueued(next) }
    }

    func playQueued(_ id: String) async {
        guard let viewer else { return }
        if let episode = knownEpisodes[id] { await play(episode); return }
        do {
            let result: EpisodesResponse = try await request(path: "/v1/podcasts/episodes", query: ["episodeId": id], viewer: viewer)
            guard self.viewer == viewer else { return }
            guard let episode = result.episodes.first else { throw SocialWireError.badResponse("Episode Is Unavailable") }
            await play(episode)
        } catch { self.error = error.localizedDescription }
    }

    func previewClip(start: Double, end: Double) {
        guard end > start, end <= player.duration else { return }
        player.preview(start: start, end: end)
    }

    func prepareClip(start: Double, end: Double, title: String, includeCaptions: Bool = true) async {
        guard !preparingClip, let episode = player.episode, let viewer else { return }
        guard episode.permitsPublicProcessing else { error = "Clips Are Unavailable for Private Episodes."; return }
        preparingClip = true
        error = nil
        defer { if self.viewer == viewer { preparingClip = false } }
        clipStatus = "Preparing Clip"
        do {
            let input = ClipInput(episodeId: episode.id, startSeconds: start, endSeconds: end, title: title, includeCaptions: includeCaptions)
            let response: ClipPreparedResponse = try await request(method: "POST", path: "/v1/podcasts/clips", body: input, viewer: viewer)
            guard self.viewer == viewer else { return }
            clipStatus = response.status.capitalized
            for _ in 0..<120 {
                try Task.checkCancellation()
                let job: ClipJobResponse = try await request(path: "/v1/podcasts/jobs", query: ["jobId": response.jobId], viewer: viewer)
                guard self.viewer == viewer else { return }
                clipStatus = job.status.capitalized
                if job.status == "ready" || job.status == "completed" || job.status == "complete" { await refresh(); return }
                if job.status == "failed" { throw SocialWireError.badResponse(job.error ?? "Clip Preparation Failed. Try Again.") }
                try await Task.sleep(for: .seconds(3))
            }
            clipStatus = "Still Processing. Refresh Clips Later."
        } catch { self.error = error.localizedDescription }
    }

    func toggleClipPublication(_ clip: PodcastClip) async {
        guard let viewer else { return }
        do {
            let collection = "app.thesocialwire.podcast.clip"
            if let uri = clip.publishedUri {
                guard ATURI(uri)?.repo == viewer else { throw SocialWireError.badResponse("This Clip Belongs to Another Viewer") }
                try await xrpc.deleteRecord(collection: collection, rkey: rkey(from: uri), expectedViewer: viewer)
                let _: JSONValue = try await request(method: "DELETE", path: "/v1/podcasts/clips", query: ["clipId": clip.id], viewer: viewer)
            } else {
                guard let audio = clip.publicAudioUrl, let video = clip.publicVideoUrl else { throw SocialWireError.badResponse("Wait for the Clip to Finish Processing") }
                var episode = knownEpisodes[clip.episodeId] ?? (player.episode?.id == clip.episodeId ? player.episode : nil)
                if episode == nil {
                    let result: EpisodesResponse = try await request(path: "/v1/podcasts/episodes", query: ["episodeId": clip.episodeId], viewer: viewer)
                    episode = result.episodes.first
                }
                guard let episode, episode.permitsPublicProcessing else { throw SocialWireError.badResponse("Private Episodes Cannot Be Published") }
                var record: [String: JSONValue] = ["$type": .string(collection), "episodeId": .string(clip.episodeId),
                    "startMillis": .number((clip.startSeconds * 1000).rounded()), "endMillis": .number((clip.endSeconds * 1000).rounded()),
                    "title": .string(clip.title), "audioUrl": .string(audio), "videoUrl": .string(video),
                    "createdAt": .string(clip.createdAt)]
                if let uri = clip.sourceUri ?? episode.sourceUri { record["sourceUri"] = .string(uri) }
                if let artwork = episode.artworkUrl { record["artworkUrl"] = .string(artwork) }
                let key = PodcastDownloadStore.key(clip.id)
                try await xrpc.putRecord(collection: collection, rkey: key, record: record, expectedViewer: viewer)
                let uri = "at://\(viewer)/\(collection)/\(key)"
                let _: JSONValue = try await request(method: "POST", path: "/v1/podcasts/clips/publish", body: ["clipId": clip.id, "uri": uri], viewer: viewer)
            }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func exportMedia(_ clip: PodcastClip, video: Bool) async -> URL? {
        guard let viewer, let raw = video ? clip.videoUrl : clip.audioUrl, let url = URL(string: raw) else { return nil }
        do {
            let data = try await gateway.podcastAsset(url: url, expectedViewer: viewer)
            guard self.viewer == viewer else { return nil }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-\(UUID().uuidString).\(video ? "mp4" : "m4a")")
            try data.write(to: file, options: .atomic)
            exportFiles.append(file)
            return file
        } catch { self.error = error.localizedDescription; return nil }
    }

    func clipURL(_ clip: PodcastClip) -> URL? {
        guard clip.publishedUri != nil else { return nil }
        return URL(string: "\(SocialWireAPIEnvironment.webBaseURLString)/podcast-clips/\(clip.id)")
    }

    private func reportProgress(id: String, position: Double, completed: Bool) {
        guard viewer != nil else { return }
        pendingProgress[id] = PodcastProgress(positionSeconds: position, updatedAt: ISO8601DateFormatter().string(from: Date()), completed: completed)
        persistPendingProgress()
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            let updates = self.pendingProgress
            let saved = await self.mutateState { state in for (id, value) in updates { state.progress[id] = value } }
            if saved {
                for (id, value) in updates where self.pendingProgress[id]?.updatedAt == value.updatedAt { self.pendingProgress[id] = nil }
                self.persistPendingProgress()
            }
            self.progressTask = nil
            if saved, let (id, value) = self.pendingProgress.first { self.reportProgress(id: id, position: value.positionSeconds, completed: value.completed) }
        }
    }

    private func persistPendingProgress() {
        guard let viewer, let data = try? JSONEncoder().encode(pendingProgress) else { return }
        UserDefaults.standard.set(data, forKey: "podcast-pending-progress.\(PodcastDownloadStore.key(viewer))")
    }

    private func refreshState(viewer: String) async throws {
        let result: StateResponse = try await request(path: "/v1/podcasts/state", viewer: viewer)
        guard self.viewer == viewer else { return }
        revision = result.revision
        state = result.state
        for (id, value) in pendingProgress { state.progress[id] = value }
        player.speed = state.playbackSpeed
        player.removesSilence = state.removeSilences
    }

    @discardableResult
    private func mutateState(_ mutation: (inout PodcastListenerState) -> Void) async -> Bool {
        guard let viewer else { return false }
        do {
            for attempt in 0..<3 {
                var proposed = state
                mutation(&proposed)
                let input = StateInput(expectedRevision: revision, state: proposed)
                do {
                    let result: StateResponse = try await request(method: "PUT", path: "/v1/podcasts/state", body: input, viewer: viewer)
                    guard self.viewer == viewer else { return false }
                    revision = result.revision
                    state = result.state
                    return true
                } catch let error as PodcastGatewayFailure where error.status == 409 && attempt < 2 {
                    try await refreshState(viewer: viewer)
                }
            }
        } catch { self.error = error.localizedDescription }
        return false
    }

    private func request<T: Decodable>(method: String = "GET", path: String, query: [String: String] = [:], viewer: String) async throws -> T {
        try await gateway.podcastRequest(method: method, path: path, query: query, expectedViewer: viewer)
    }
    private func request<T: Decodable, Body: Encodable>(method: String, path: String, body: Body, viewer: String) async throws -> T {
        try await gateway.podcastRequest(method: method, path: path, body: JSONEncoder().encode(body), expectedViewer: viewer)
    }

    private struct EpisodeResponse: Decodable { let episode: PodcastEpisode }
    private struct ClipInput: Encodable { let episodeId: String; let startSeconds: Double; let endSeconds: Double; let title: String; let includeCaptions: Bool }
    private struct ClipPreparedResponse: Decodable { let clipId: String; let jobId: String; let status: String }
    private struct ClipJobResponse: Decodable { let id: String; let status: String; let error: String? }
    private struct ShowsResponse: Decodable { let shows: [PodcastShow] }
    private struct EpisodesResponse: Decodable { let episodes: [PodcastEpisode]; let cursor: String? }
    private struct ResolveResponse: Decodable { let show: PodcastShow; let episodes: [PodcastEpisode]; let shows: [PodcastShow]? }
    private struct TranscriptResponse: Decodable { let transcripts: [PodcastTranscript] }
    private struct ClipsResponse: Decodable { let clips: [PodcastClip] }
    private struct StateResponse: Decodable { let revision: Int; let state: PodcastListenerState }
    private struct StateInput: Encodable { let expectedRevision: Int; let state: PodcastListenerState }
    private struct JobResponse: Decodable { let id: String; let status: String }
    private struct AnalysisResponse: Decodable { let status: String; let intervals: [PodcastSilenceInterval]? }
}
