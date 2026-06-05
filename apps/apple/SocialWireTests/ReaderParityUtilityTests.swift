import Foundation
import Testing
@testable import SocialWire

@Suite("EffectiveUnreadCount")
struct EffectiveUnreadCountTests {
    @Test("reconciles server count with cached read rows")
    func reconcilesWithCachedReadRows() {
        let count = EffectiveUnreadCount.effectivePublicationUnreadCount(
            serverCount: 5,
            cachedEntryIds: ["a", "b", "c"],
            isEntryRead: { $0 == "a" || $0 == "b" }
        )
        #expect(count == 3)
    }

    @Test("returns server count when cache is empty")
    func emptyCacheUsesServerCount() {
        let count = EffectiveUnreadCount.effectivePublicationUnreadCount(
            serverCount: 4,
            cachedEntryIds: [],
            isEntryRead: { _ in false }
        )
        #expect(count == 4)
    }
}

@Suite("ArticlePresentationResolver")
struct ArticlePresentationResolverTests {
    @Test("prefers substantial HTML")
    func substantialHTML() {
        let html = String(repeating: "word ", count: 120)
        let mode = ArticlePresentationResolver.resolve(
            contentHtml: "<p>\(html)</p>",
            embedUrl: "https://example.com/a",
            originalUrl: "https://example.com/a"
        )
        #expect(mode == .html)
    }

    @Test("uses web preview for thin summaries with embed URL")
    func thinSummaryUsesPreview() {
        let mode = ArticlePresentationResolver.resolve(
            contentHtml: "<p>Short</p>",
            embedUrl: "https://example.com/a",
            originalUrl: "https://example.com/a"
        )
        #expect(mode == .webPreview)
    }
}

@Suite("SavedLinkEmbedURL")
struct SavedLinkEmbedURLTests {
    @Test("prefers linkedWebUrl for Pocket reader wrappers")
    func pocketWrapperUsesLinkedWebUrl() {
        let save = MergedLatrSave.external(
            MergedLatrExternalSave(
                normalizedUrl: "https://getpocket.com/read/123",
                url: "https://getpocket.com/read/123",
                savedAt: "2026-01-01T00:00:00.000Z",
                externalRkey: "ext",
                itemRkey: "item",
                externalUri: "at://did/link.latr.saved.external/ext",
                itemUri: "at://did/link.latr.saved.item/item",
                subjectUri: "at://did/link.latr.saved.external/ext",
                state: "unread",
                linkedWebUrl: "https://example.com/article"
            )
        )
        #expect(SavedLinkEmbedURL.resolveEmbedURL(for: save) == "https://example.com/article")
    }
}
