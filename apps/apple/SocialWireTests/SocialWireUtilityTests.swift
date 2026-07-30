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
        snapshot.expandedFolderRkeys.insert("folder-a")
        SidebarExpandedKeysStorage.save(viewerDid: did, snapshot: snapshot)

        let loaded = SidebarExpandedKeysStorage.load(viewerDid: did)
        #expect(loaded.foldersSectionExpanded)
        #expect(loaded.publicationsSectionExpanded)
        #expect(loaded.expandedFolderRkeys == ["folder-a"])
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
