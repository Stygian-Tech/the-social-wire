import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class PodcastDownloadStore {
    private(set) var progress: [String: Double] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var downloadedIDs: Set<String> = []
    private(set) var episodes: [String: PodcastEpisode] = [:]
    @ObservationIgnored var onCompletion: ((PodcastEpisode) -> Void)?
    @ObservationIgnored var onAuthenticationChallenge: ((PodcastEpisode, HTTPURLResponse) async throws -> URLRequest)?
    @ObservationIgnored private var nonceRetries: [String: Int] = [:]
    @ObservationIgnored private var retryingIDs: Set<String> = []
    private(set) var storageBytes: Int64 = 0
    @ObservationIgnored private var viewer: String?
    @ObservationIgnored private var orphanedTasks: [Int: String] = [:]
    @ObservationIgnored private var tasks: [Int: String] = [:]
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var directory: URL?

    func configure(viewer: String?) {
        guard self.viewer != viewer else { return }
        session?.invalidateAndCancel()
        self.viewer = viewer
        tasks = [:]
        orphanedTasks = [:]
        progress = [:]
        errors = [:]
        downloadedIDs = []
        episodes = [:]
        nonceRetries = [:]
        retryingIDs = []
        storageBytes = 0
        guard let viewer else { directory = nil; session = nil; return }
        let key = Self.key(viewer)
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PodcastDownloads/\(key)", isDirectory: true)
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let configuration: URLSessionConfiguration
#if os(iOS)
        configuration = .background(withIdentifier: "app.thesocialwire.podcast-downloads.\(key)")
        configuration.sessionSendsLaunchEvents = true
#else
        configuration = .default
#endif
        configuration.isDiscretionary = false
        let delegate = PodcastDownloadDelegate(finished: { [weak self] task, url, response, error in
            Task { @MainActor [weak self] in
                guard let self, self.viewer == viewer else {
                    if let url { try? FileManager.default.removeItem(at: url) }
                    return
                }
                self.finished(task: task, url: url, response: response, error: error)
            }
        }, progressed: { [weak self] task, value in
            Task { @MainActor [weak self] in
                guard let self, self.viewer == viewer, let id = self.tasks[task] else { return }
                self.progress[id] = value
            }
        })
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        restoreFiles()
        let saved = UserDefaults.standard.dictionary(forKey: "podcast-download-tasks.\(key)") as? [String: String] ?? [:]
        tasks = Dictionary(uniqueKeysWithValues: saved.compactMap { task, episode in Int(task).map { ($0, episode) } })
        for id in tasks.values { progress[id] = 0 }
        session?.getAllTasks { [weak self] restoredTasks in
            let snapshots = restoredTasks.map { ($0.taskIdentifier, $0.taskDescription) }
            Task { @MainActor [weak self] in
                guard let self, self.viewer == viewer else { return }
                let activeIDs = Set(snapshots.map { $0.0 })
                for (task, id) in self.tasks where !activeIDs.contains(task) {
                    self.orphanedTasks[task] = id
                    self.tasks[task] = nil
                    self.progress[id] = nil
                    if !self.downloadedIDs.contains(id) { self.errors[id] = "Download Interrupted. Retry Download." }
                }
                for (task, id) in snapshots {
                    if let id, self.tasks[task] == nil {
                        self.tasks[task] = id
                        self.progress[id] = 0
                    }
                }
                self.persistTasks()
            }
        }
    }

    func download(_ episode: PodcastEpisode, request: URLRequest? = nil) {
        guard localURL(episode.id) == nil, progress[episode.id] == nil else { return }
        let resolvedRequest: URLRequest
        if let request { resolvedRequest = request }
        else {
            guard !episode.isPrivate, let url = URL(string: episode.audioURL), url.scheme == "https" else { return }
            resolvedRequest = URLRequest(url: url)
        }
        nonceRetries[episode.id] = 0
        startDownload(episode, request: resolvedRequest)
    }

    private func startDownload(_ episode: PodcastEpisode, request: URLRequest) {
        guard let session else { return }
        episodes[episode.id] = episode
        persistEpisodes()
        let task = session.downloadTask(with: request)
        task.taskDescription = episode.id
        tasks[task.taskIdentifier] = episode.id
        progress[episode.id] = 0
        errors[episode.id] = nil
        persistTasks()
        task.resume()
    }

    func cancel(_ id: String) {
        retryingIDs.remove(id)
        progress[id] = nil
        guard let taskID = tasks.first(where: { $0.value == id })?.key else { return }
        let activeSession = session
        activeSession?.getAllTasks { tasks in tasks.first(where: { $0.taskIdentifier == taskID })?.cancel() }
        tasks[taskID] = nil
        progress[id] = nil
        persistTasks()
    }

    func delete(_ id: String) {
        cancel(id)
        guard let directory else { return }
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(Self.key(id)))
            downloadedIDs.remove(id)
            episodes[id] = nil
            persistEpisodes()
            persistIndex()
            calculateSize()
        } catch { errors[id] = error.localizedDescription }
    }

    func localURL(_ id: String) -> URL? {
        guard let directory, downloadedIDs.contains(id) else { return nil }
        let url = directory.appendingPathComponent(Self.key(id))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func finished(task: Int, url: URL?, response: HTTPURLResponse?, error: String?) {
        guard let id = tasks.removeValue(forKey: task) ?? orphanedTasks.removeValue(forKey: task) else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return
        }
        guard !tasks.values.contains(id) else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return
        }
        if let response, response.statusCode == 401,
           response.value(forHTTPHeaderField: "DPoP-Nonce") != nil,
           nonceRetries[id, default: 0] < 1, let episode = episodes[id], episode.isPrivate,
           let onAuthenticationChallenge {
            nonceRetries[id] = 1
            retryingIDs.insert(id)
            progress[id] = 0
            persistTasks()
            let expectedViewer = viewer
            Task { [weak self] in
                do {
                    let request = try await onAuthenticationChallenge(episode, response)
                    guard let self, self.viewer == expectedViewer, self.retryingIDs.remove(id) != nil else { return }
                    self.startDownload(episode, request: request)
                } catch {
                    guard let self, self.viewer == expectedViewer, self.retryingIDs.remove(id) != nil else { return }
                    self.progress[id] = nil
                    self.errors[id] = "Sign In Again, Then Retry Download."
                }
            }
            return
        }
        progress[id] = nil
        persistTasks()
        guard let url, let directory else { errors[id] = error ?? "Download Failed"; return }
        do {
            let destination = directory.appendingPathComponent(Self.key(id))
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: url, to: destination)
            var resourceURL = destination
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try resourceURL.setResourceValues(values)
            downloadedIDs.insert(id)
            errors[id] = nil
            persistIndex()
            calculateSize()
            if let episode = episodes[id] { onCompletion?(episode) }
        } catch { errors[id] = "Could Not Store Download. Check Available Device Storage." }
    }

    private func restoreFiles() {
        guard let viewer else { return }
        if let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("episodes.json")) {
            episodes = (try? JSONDecoder().decode([String: PodcastEpisode].self, from: data)) ?? [:]
        }
        downloadedIDs = Set(UserDefaults.standard.stringArray(forKey: "podcast-download-index.\(Self.key(viewer))") ?? [])
        downloadedIDs = downloadedIDs.filter { id in
            guard let directory else { return false }
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.key(id)).path)
        }
        calculateSize()
    }

    private func persistEpisodes() {
        guard let directory, let data = try? JSONEncoder().encode(episodes) else { return }
        let file = directory.appendingPathComponent("episodes.json")
        do {
            try data.write(to: file, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var resource = file
            try resource.setResourceValues(values)
        } catch { }
    }

    func exportFilename(for episode: PodcastEpisode) -> String {
        let mimeExtensions = ["audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/aac": "aac", "audio/ogg": "ogg", "audio/wav": "wav"]
        let suffix = mimeExtensions[episode.audioMimeType ?? ""] ?? "mp3"
        let title = episode.title.components(separatedBy: CharacterSet(charactersIn: "/\\:" )).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return String((title.isEmpty ? "Podcast" : title).prefix(100)) + "." + suffix
    }

    private func persistIndex() {
        guard let viewer else { return }
        UserDefaults.standard.set(Array(downloadedIDs), forKey: "podcast-download-index.\(Self.key(viewer))")
    }

    private func persistTasks() {
        guard let viewer else { return }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: tasks.map { (String($0.key), $0.value) }), forKey: "podcast-download-tasks.\(Self.key(viewer))")
    }

    private func calculateSize() {
        guard let directory else { return }
        storageBytes = downloadedIDs.reduce(0) { sum, id in
            sum + ((try? directory.appendingPathComponent(Self.key(id)).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
        }
    }

    nonisolated static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
