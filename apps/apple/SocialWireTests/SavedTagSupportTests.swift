import Foundation
import Testing
@testable import SocialWire

@Suite("Saved tag support")
struct SavedTagSupportTests {
    @Test("state transitions preserve tags and replacement can clear them")
    func stateAndTagReplacement() {
        let save = makeSave(id: "one", tags: ["News", "Long Read"])

        #expect(save.withState("archived").tags == ["News", "Long Read"])
        #expect(save.withTags(["Research"]).tags == ["Research"])
        #expect(save.withTags([]).tags.isEmpty)
    }

    @Test("tag counts preserve exact spelling and count each bookmark once")
    func exactTagCounts() {
        let counts = SavedTagCatalog.counts(in: [
            makeSave(id: "one", tags: ["News", "News", "swift"]),
            makeSave(id: "two", tags: ["news", "swift"]),
        ])

        #expect(counts.first(where: { $0.tag == "News" })?.count == 1)
        #expect(counts.first(where: { $0.tag == "news" })?.count == 1)
        #expect(counts.first(where: { $0.tag == "swift" })?.count == 2)
    }

    @Test("stored selection is viewer scoped and exact")
    func storedSelection() throws {
        let suite = "SavedTagSupportTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        SavedTagSelectionStorage.save("Long Read", viewerDid: "did:plc:alice", defaults: defaults)
        SavedTagSelectionStorage.save("long read", viewerDid: "did:plc:bob", defaults: defaults)

        #expect(SavedTagSelectionStorage.load(viewerDid: "did:plc:alice", defaults: defaults) == "Long Read")
        #expect(SavedTagSelectionStorage.load(viewerDid: "did:plc:bob", defaults: defaults) == "long read")
        SavedTagSelectionStorage.save(nil, viewerDid: "did:plc:alice", defaults: defaults)
        #expect(SavedTagSelectionStorage.load(viewerDid: "did:plc:alice", defaults: defaults) == nil)
    }

    @Test("mutation progress accumulates pages and normalizes empty cursors")
    func mutationProgress() {
        var progress = SavedTagMutationProgress(tag: "News", action: .delete)
        progress.applyPage(scanned: 25, matched: 8, updated: 8, cursor: "next")
        progress.applyPage(scanned: 10, matched: 2, updated: 2, cursor: "  ")

        #expect(progress.scanned == 35)
        #expect(progress.matched == 10)
        #expect(progress.updated == 10)
        #expect(progress.cursor == nil)
        #expect(progress.isComplete)
    }

    private func makeSave(id: String, tags: [String]) -> MergedLatrSave {
        .external(MergedLatrExternalSave(
            normalizedUrl: "https://example.com/\(id)",
            url: "https://example.com/\(id)",
            savedAt: "2026-08-30T12:00:00Z",
            externalRkey: "",
            itemRkey: "at://did:plc:viewer/community.lexicon.bookmarks.bookmark/\(id)",
            externalUri: "https://example.com/\(id)",
            itemUri: "at://did:plc:viewer/community.lexicon.bookmarks.bookmark/\(id)",
            subjectUri: "https://example.com/\(id)",
            state: "unread",
            lastOpenedAt: nil,
            title: nil,
            excerpt: nil,
            image: nil,
            site: nil,
            author: nil,
            publishedAt: nil,
            language: nil,
            linkedWebUrl: nil,
            rowSubtitle: nil,
            tags: tags
        ))
    }
}
