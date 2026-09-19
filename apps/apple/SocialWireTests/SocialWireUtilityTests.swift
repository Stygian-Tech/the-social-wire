import Foundation
import Testing
@testable import SocialWire

@Suite("SocialWire utilities")
struct SocialWireUtilityTests {
    @Test("AT URI parsing")
    func aturiParsing() {
        let uri = ATURI("at://did:plc:alice/site.standard.document/abc123")
        #expect(uri?.repo == "did:plc:alice")
        #expect(uri?.collection == "site.standard.document")
        #expect(uri?.rkey == "abc123")
    }

    @Test("L@tr external rkey matches canonical base32")
    func latrExternalRKeyMatchesCanonical() {
        let rkey = DeterministicKeys.latrExternalRKey(normalizedURL: "https://example.com/article")
        #expect(rkey == "MMSTQKIENDT2HHAGGI6J4OXJR4YQOLLEDS5TP2RXSF7VNO7LKU4Q")
    }

    @Test("legacy iOS keys are detectable for read-repair")
    func legacyIOSKeysAreDetectable() {
        let subjectURI = "at://did:plc:alice/site.standard.document/abc123"
        let canonical = DeterministicKeys.latrItemRKey(subjectURI: subjectURI)
        let legacy = DeterministicKeys.legacyIOSLatrItemRKey(subjectURI: subjectURI)
        #expect(canonical != legacy)
        #expect(legacy == canonical.lowercased())
    }

    @Test("PublicURLNormalizer promotes HTTP and strips bridge noise")
    func publicURLNormalizerPromotesHTTPAndStripsBridgeNoise() {
        let normalized = PublicURLNormalizer.normalizeHttpURLToHTTPS("http://example.com/post?bridge_completed=1&x=2")
        #expect(normalized == "https://example.com/post?x=2")
    }

    @Test("L@tr merge pairs external rows and filter splits active vs archived")
    func latrMergePairsExternalRowsAndFilterSplitsActiveVsArchived() {
        let activeExternal = RepoRecord(
            uri: "at://did:plc:me/\(PDSRecordService.latrSavedExternal)/ext-active",
            cid: nil,
            value: LatrSavedExternalRecord(
                type: PDSRecordService.latrSavedExternal,
                url: "https://example.com/active",
                normalizedUrl: "https://example.com/active",
                fingerprint: "abc",
                createdAt: "2026-05-16T00:00:00.000Z",
                title: "Active Example",
                site: "example.com",
                image: "https://example.com/thumb.jpg"
            )
        )
        let archivedExternal = RepoRecord(
            uri: "at://did:plc:me/\(PDSRecordService.latrSavedExternal)/ext-archived",
            cid: nil,
            value: LatrSavedExternalRecord(
                type: PDSRecordService.latrSavedExternal,
                url: "https://example.com/archived",
                normalizedUrl: "https://example.com/archived",
                fingerprint: "def",
                createdAt: "2026-05-16T00:00:00.000Z",
                title: "Archived Example"
            )
        )
        let activeItem = RepoRecord(
            uri: "at://did:plc:me/\(PDSRecordService.latrSavedItem)/item-active",
            cid: nil,
            value: LatrSavedItemRecord(
                type: PDSRecordService.latrSavedItem,
                subjectUri: "at://did:plc:me/\(PDSRecordService.latrSavedExternal)/ext-active",
                savedAt: "2026-05-16T01:00:00.000Z",
                state: "unread"
            )
        )
        let archivedItem = RepoRecord(
            uri: "at://did:plc:me/\(PDSRecordService.latrSavedItem)/item-archived",
            cid: nil,
            value: LatrSavedItemRecord(
                type: PDSRecordService.latrSavedItem,
                subjectUri: "at://did:plc:me/\(PDSRecordService.latrSavedExternal)/ext-archived",
                savedAt: "2026-05-16T02:00:00.000Z",
                state: "archived",
                previewExcerpt: "Preview excerpt"
            )
        )

        let merged = PDSRecordService.merge(
            externals: [activeExternal, archivedExternal],
            items: [activeItem, archivedItem]
        )
        #expect(merged.count == 2)

        let activeOnly = PDSRecordService.filterMergedLatrSavesByState(merged, state: .active)
        #expect(activeOnly.count == 1)
        #expect(activeOnly.first?.title == "Active Example")
        #expect(activeOnly.first?.image == "https://example.com/thumb.jpg")

        let archivedOnly = PDSRecordService.filterMergedLatrSavesByState(merged, state: .archived)
        #expect(archivedOnly.count == 1)
        #expect(archivedOnly.first?.title == "Archived Example")
        #expect(archivedOnly.first?.excerpt == "Preview excerpt")
    }

    @Test("HTML wrapper contains CSP and readable colors")
    func htmlWrapperContainsCSP() {
        let wrapped = HTMLRenderer.wrappedHTML("<p>Hello</p>", colorScheme: .light)
        #expect(wrapped.contains("Content-Security-Policy"))
        #expect(wrapped.contains("media-src https:"))
        #expect(wrapped.contains("<p>Hello</p>"))
        #expect(wrapped.contains("#1C1C1E"))
        #expect(wrapped.contains("max-width: 72ch"))
        #expect(wrapped.contains("overflow-x: auto"))
        #expect(wrapped.contains("white-space: pre"))
        #expect(wrapped.contains("video, audio { width: 100%; }"))
    }

    @Test("HTML wrapper uses light text in dark mode")
    func htmlWrapperUsesLightTextInDarkMode() {
        let wrapped = HTMLRenderer.wrappedHTML("<p>Hello</p>", colorScheme: .dark)
        #expect(wrapped.contains("#F5F5F7"))
        #expect(wrapped.contains("!important"))
    }

    @Test("prepareArticleBody repairs escaped RSS summary HTML")
    func prepareArticleBodyRepairsEscapedRssSummary() {
        let repaired = HTMLRenderer.prepareArticleBody("<p>&lt;p&gt;Hello&lt;/p&gt;</p>")
        #expect(repaired == "<p>Hello</p>")
    }

    @Test("prepareArticleBody wraps plain text")
    func prepareArticleBodyWrapsPlainText() {
        let wrapped = HTMLRenderer.prepareArticleBody("Line one\n\nLine two")
        #expect(wrapped == "<p>Line one</p><p>Line two</p>")
    }

    @Test("prepareArticleBody linkifies bare URLs outside links and code")
    func prepareArticleBodyLinkifiesBareURLs() {
        let wrapped = HTMLRenderer.prepareArticleBody(
            """
            <p>Visit www.example.com or <a href="https://linked.example">https://linked.example</a>.</p>
            <pre>https://code.example</pre>
            """
        )
        #expect(wrapped.contains(#"<a href="https://www.example.com">www.example.com</a>"#))
        #expect(wrapped.components(separatedBy: #"href="https://linked.example""#).count == 2)
        #expect(wrapped.contains("<pre>https://code.example</pre>"))
    }

    @Test("prepareArticleBody keeps URL punctuation outside links")
    func prepareArticleBodyKeepsURLPunctuationOutsideLinks() {
        let wrapped = HTMLRenderer.prepareArticleBody(
            "Read https://example.com/article_(reader), then continue."
        )
        #expect(wrapped.contains(#"href="https://example.com/article_(reader)""#))
        #expect(wrapped.contains("</a>, then continue."))
    }

    @Test("prepareArticleBody replaces embeds with safe external links")
    func prepareArticleBodyReplacesEmbeds() {
        let wrapped = HTMLRenderer.prepareArticleBody(
            """
            <iframe src="http://video.example/watch/1"></iframe>
            <embed src="javascript:alert(1)">
            """
        )
        #expect(!wrapped.contains("<iframe"))
        #expect(!wrapped.contains("<embed"))
        #expect(!wrapped.contains("javascript:"))
        #expect(wrapped.contains("Open Embedded Media"))
        #expect(wrapped.contains(#"href="https://video.example/watch/1""#))
    }

    @Test("prepareArticleBody applies safe media defaults")
    func prepareArticleBodyAppliesSafeMediaDefaults() {
        let wrapped = HTMLRenderer.prepareArticleBody(
            #"<video controls preload="auto" autoplay src="http://example.com/video.mp4" poster="javascript:evil()"></video><audio src="javascript:evil()"></audio>"#
        )
        #expect(!wrapped.contains("autoplay"))
        #expect(wrapped.components(separatedBy: "controls").count == 3)
        #expect(wrapped.contains(#"preload="metadata""#))
        #expect(wrapped.contains(#"src="https://example.com/video.mp4""#))
        #expect(!wrapped.contains("javascript:"))
    }

    @Test("prepareArticleBody strips executable publisher markup")
    func prepareArticleBodyStripsExecutableMarkup() {
        let wrapped = HTMLRenderer.prepareArticleBody(
            #"<style>body { display: none }</style><p style="color:red" onclick="evil()">Body</p><a href="javascript:evil()">Unsafe</a><script>evil()</script>"#
        )
        #expect(!wrapped.contains("<style"))
        #expect(!wrapped.contains("style="))
        #expect(!wrapped.contains("onclick"))
        #expect(!wrapped.contains("<script"))
        #expect(!wrapped.contains("evil()"))
        #expect(!wrapped.contains("javascript:"))
        #expect(wrapped.contains("<a>Unsafe</a>"))
        #expect(wrapped.contains("<p>Body</p>"))
    }

    @Test("sidebar expanded keys persist per viewer did")
    func sidebarExpandedKeysPersistPerViewerDid() {
        let defaults = UserDefaults.standard
        let storageKey = SidebarExpandedKeysStorage.storageKey
        let prior = defaults.string(forKey: storageKey)
        defer {
            if let prior {
                defaults.set(prior, forKey: storageKey)
            } else {
                defaults.removeObject(forKey: storageKey)
            }
        }

        defaults.removeObject(forKey: storageKey)
        let did = "did:plc:sidebar-expand-test"
        var snapshot = SidebarExpandedSnapshot.default()
        snapshot.subscribedFeedExpanded = true
        snapshot.followingFeedExpanded = false
        snapshot.foldersSectionExpanded = true
        snapshot.publicationsSectionExpanded = true
        snapshot.expandedFolderRkeys.insert("folder-a")
        SidebarExpandedKeysStorage.save(viewerDid: did, snapshot: snapshot)

        let loaded = SidebarExpandedKeysStorage.load(viewerDid: did)
        #expect(loaded.subscribedFeedExpanded)
        #expect(!loaded.followingFeedExpanded)
        #expect(loaded.foldersSectionExpanded)
        #expect(loaded.publicationsSectionExpanded)
        #expect(loaded.expandedFolderRkeys == ["folder-a"])
        #expect(SidebarExpandedKeysStorage.load(viewerDid: "did:plc:another-viewer") == .default())
    }

    @Test("sidebar expanded keys migrate optimistic folder rkeys")
    func sidebarExpandedKeysMigrateOptimisticFolderRkeys() {
        let defaults = UserDefaults.standard
        let storageKey = SidebarExpandedKeysStorage.storageKey
        let prior = defaults.string(forKey: storageKey)
        defer {
            if let prior {
                defaults.set(prior, forKey: storageKey)
            } else {
                defaults.removeObject(forKey: storageKey)
            }
        }

        defaults.removeObject(forKey: storageKey)
        let did = "did:plc:sidebar-expand-migrate"
        var snapshot = SidebarExpandedSnapshot.default()
        snapshot.expandedFolderRkeys.insert("optimistic-folder-old")
        SidebarExpandedKeysStorage.save(viewerDid: did, snapshot: snapshot)

        SidebarExpandedKeysStorage.migrateFolderExpandKey(
            viewerDid: did,
            oldRkey: "optimistic-folder-old",
            newRkey: "real-folder-rkey"
        )

        let loaded = SidebarExpandedKeysStorage.load(viewerDid: did)
        #expect(loaded.expandedFolderRkeys == ["real-folder-rkey"])
    }
}

@Suite("Image cache request sharing")
struct ImageCacheRequestSharingTests {
    private let url = URL(string: "https://example.test/image.png")!

    @Test("Concurrent identical requests share one download and populate the cache")
    func concurrentRequests() async throws {
        let downloader = try ImageCacheTestDownloader()
        defer { downloader.removeFixture() }
        let cache = ImageCacheService(download: { try await downloader.download($0) })
        let requests = (0..<8).map { _ in
            Task { await cache.image(for: url, maxPixelSize: 96) != nil }
        }
        try await waitUntil { await cache.pendingRequestCount == 8 }
        try await waitUntil { await downloader.callCount == 1 }
        await downloader.complete(call: 1)
        for request in requests { #expect(await request.value) }
        #expect(await cache.image(for: url, maxPixelSize: 96) != nil)
        #expect(await downloader.callCount == 1)
        #expect(await cache.pendingRequestCount == 0)
        #expect(await downloader.completedFilesAreRemoved)
    }

    @Test("Failed shared downloads release all callers and can retry")
    func failureCanRetry() async throws {
        let downloader = try ImageCacheTestDownloader()
        defer { downloader.removeFixture() }
        let cache = ImageCacheService(download: { try await downloader.download($0) })
        let first = Task { await cache.image(for: url, maxPixelSize: 96) != nil }
        let second = Task { await cache.image(for: url, maxPixelSize: 96) != nil }
        try await waitUntil { await cache.pendingRequestCount == 2 }
        try await waitUntil { await downloader.callCount == 1 }
        await downloader.complete(call: 1, fail: true)
        #expect(await !first.value)
        #expect(await !second.value)
        #expect(await downloader.completedFiles.isEmpty)
        let retry = Task { await cache.image(for: url, maxPixelSize: 96) != nil }
        try await waitUntil { await downloader.callCount == 2 }
        await downloader.complete(call: 2)
        #expect(await retry.value)
        #expect(await downloader.completedFilesAreRemoved)
    }

    @Test("Cancelling one caller leaves the other caller's shared download running")
    func oneCallerCancels() async throws {
        let downloader = try ImageCacheTestDownloader()
        defer { downloader.removeFixture() }
        let cache = ImageCacheService(download: { try await downloader.download($0) })
        let first = Task { await cache.image(for: url, maxPixelSize: 96) != nil }
        let second = Task { await cache.image(for: url, maxPixelSize: 96) != nil }
        try await waitUntil { await cache.pendingRequestCount == 2 }
        try await waitUntil { await downloader.callCount == 1 }
        first.cancel()
        #expect(await !first.value)
        #expect(await cache.pendingRequestCount == 1)
        #expect(await downloader.cancelledCalls.isEmpty)
        await downloader.complete(call: 1)
        #expect(await second.value)
        #expect(await downloader.callCount == 1)
        #expect(await downloader.completedFilesAreRemoved)
    }

    @Test("Cancelling the last caller cancels the download and permits a fresh request")
    func allCallersCancel() async throws {
        let downloader = try ImageCacheTestDownloader()
        defer { downloader.removeFixture() }
        let cache = ImageCacheService(download: { try await downloader.download($0) })
        let first = Task { await cache.image(for: url, maxPixelSize: 96) != nil }
        try await waitUntil { await downloader.callCount == 1 }
        first.cancel()
        #expect(await !first.value)
        try await waitUntil { await downloader.cancelledCalls == [1] }
        #expect(await cache.pendingRequestCount == 0)
        let retry = Task { await cache.image(for: url, maxPixelSize: 96) != nil }
        try await waitUntil { await downloader.callCount == 2 }
        await downloader.complete(call: 2)
        #expect(await retry.value)
        #expect(await downloader.completedFilesAreRemoved)
    }

    @Test("Rejected image downloads remove their temporary files", arguments: [
        "status", "declaredSize", "actualSize", "invalidImage",
    ])
    func rejectedDownloadRemovesFile(reason: String) async throws {
        let downloader = try ImageCacheTestDownloader()
        defer { downloader.removeFixture() }
        let cache = ImageCacheService(download: { try await downloader.download($0) })
        let request = Task { await cache.image(for: url, maxPixelSize: 96) != nil }
        try await waitUntil { await downloader.callCount == 1 }
        switch reason {
        case "status":
            await downloader.complete(call: 1, statusCode: 404)
        case "declaredSize":
            await downloader.complete(call: 1, expectedContentLength: 16 * 1024 * 1024 + 1)
        case "actualSize":
            await downloader.complete(call: 1, data: Data(count: 16 * 1024 * 1024 + 1))
        default:
            await downloader.complete(call: 1, data: Data("invalid image".utf8))
        }
        #expect(await !request.value)
        #expect(await downloader.completedFilesAreRemoved)
        #expect(await cache.pendingRequestCount == 0)
    }

    @Test("A download completing after cancellation still removes its temporary file")
    func cancelledDownloadRemovesFile() async throws {
        let downloader = try ImageCacheTestDownloader(completeOnCancellation: true)
        defer { downloader.removeFixture() }
        let cache = ImageCacheService(download: { try await downloader.download($0) })
        let request = Task { await cache.image(for: url, maxPixelSize: 96) != nil }
        try await waitUntil { await downloader.callCount == 1 }
        request.cancel()
        #expect(await !request.value)
        try await waitUntil { await downloader.cancelledCalls == [1] }
        try await waitUntil { await downloader.completedFilesAreRemoved }
        #expect(await cache.pendingRequestCount == 0)
    }

    private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await condition())
    }
}

private actor ImageCacheTestDownloader {
    nonisolated let directory: URL
    private let completeOnCancellation: Bool
    private(set) var callCount = 0
    private(set) var cancelledCalls: Set<Int> = []
    private(set) var completedFiles: [URL] = []
    private var pending: [Int: CheckedContinuation<(URL, URLResponse), any Error>] = [:]

    var completedFilesAreRemoved: Bool {
        !completedFiles.isEmpty && completedFiles.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        }
    }

    init(completeOnCancellation: Bool = false) throws {
        self.completeOnCancellation = completeOnCancellation
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    nonisolated func removeFixture() {
        try? FileManager.default.removeItem(at: directory)
    }

    func download(_ url: URL) async throws -> (URL, URLResponse) {
        callCount += 1
        let call = callCount
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[call] = $0 }
        } onCancel: {
            Task { await self.cancel(call: call) }
        }
    }

    func complete(
        call: Int, fail: Bool = false, statusCode: Int = 200,
        data: Data? = nil, expectedContentLength: Int? = nil
    ) {
        guard let continuation = pending.removeValue(forKey: call) else { return }
        if fail {
            continuation.resume(throwing: URLError(.networkConnectionLost))
        } else {
            do {
                let temporaryURL = directory.appendingPathComponent(UUID().uuidString + ".png")
                let image = data ?? Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=")!
                try image.write(to: temporaryURL)
                completedFiles.append(temporaryURL)
                let headers = expectedContentLength.map { ["Content-Length": String($0)] }
                let response = HTTPURLResponse(
                    url: temporaryURL, statusCode: statusCode, httpVersion: nil, headerFields: headers
                )!
                continuation.resume(returning: (temporaryURL, response))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func cancel(call: Int) {
        cancelledCalls.insert(call)
        if completeOnCancellation {
            complete(call: call)
        } else {
            pending.removeValue(forKey: call)?.resume(throwing: CancellationError())
        }
    }
}
