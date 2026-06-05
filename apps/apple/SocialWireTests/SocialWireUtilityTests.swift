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

    @Test("read-state rkey is deterministic base32")
    func readStateRKeyIsDeterministicBase32() throws {
        let subjectURI = "at://did:plc:alice/site.standard.document/abc123"
        let first = DeterministicKeys.entryReadStateRKey(subjectURI: subjectURI)
        let second = DeterministicKeys.entryReadStateRKey(subjectURI: subjectURI)
        #expect(first == second)
        #expect(first == "JPFAJWZIZ7VWQJ3CR2L7PEPRNZBZ6LJ7MKKO3RKWB642BF64NBXQ")
        #expect(first.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".contains($0) })
    }

    @Test("L@tr external rkey matches canonical base32")
    func latrExternalRKeyMatchesCanonical() {
        let rkey = DeterministicKeys.latrExternalRKey(normalizedURL: "https://example.com/article")
        #expect(rkey == "MMSTQKIENDT2HHAGGI6J4OXJR4YQOLLEDS5TP2RXSF7VNO7LKU4Q")
    }

    @Test("legacy iOS keys are detectable for read-repair")
    func legacyIOSKeysAreDetectable() {
        let subjectURI = "at://did:plc:alice/site.standard.document/abc123"
        let canonical = DeterministicKeys.entryReadStateRKey(subjectURI: subjectURI)
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

    @Test("HTML wrapper contains CSP")
    func htmlWrapperContainsCSP() {
        let wrapped = HTMLRenderer.wrappedHTML("<p>Hello</p>")
        #expect(wrapped.contains("Content-Security-Policy"))
        #expect(wrapped.contains("<p>Hello</p>"))
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
