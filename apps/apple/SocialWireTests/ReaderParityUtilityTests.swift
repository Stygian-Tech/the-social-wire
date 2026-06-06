import Foundation
import Testing
@testable import SocialWire

@Suite("PublicationUnreadCountLookup")
struct PublicationUnreadCountLookupTests {
    @Test("lookup matches URL-encoded publication ids")
    func lookupMatchesEncodedPublicationIds() {
        let canonical = "at://did:plc:abc/site.standard.publication/rkey1"
        let encoded = "at%3A%2F%2Fdid%3Aplc%3Aabc%2Fsite.standard.publication%2Frkey1"
        let counts = [canonical: 3]
        #expect(PublicationUnreadCountLookup.lookup(in: counts, publicationId: encoded) == 3)
    }

    @Test("lookup does not match different publication collections")
    func lookupDoesNotMatchDifferentCollections() {
        let site = "at://did:plc:abc/site.standard.publication/rkey1"
        let other = "at://did:plc:abc/other.collection/rkey1"
        let counts = [other: 2]
        #expect(PublicationUnreadCountLookup.lookup(in: counts, publicationId: site) == 0)
        #expect(!PublicationUnreadCountLookup.publicationIdsMatch(site, other))
    }

    @Test("store replaces prior normalized key")
    func storeReplacesPriorNormalizedKey() {
        var counts = [
            "at%3A%2F%2Fdid%3Aplc%3Aabc%2Fsite.standard.publication%2Frkey1": 4,
        ]
        PublicationUnreadCountLookup.store(1, for: "at://did:plc:abc/site.standard.publication/rkey1", in: &counts)
        #expect(counts.count == 1)
        #expect(counts["at://did:plc:abc/site.standard.publication/rkey1"] == 1)
    }
}

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

@Suite("CompactReaderNavigation")
struct CompactReaderNavigationTests {
    @Test("list source opens publications pane")
    func listSourceOpensPublications() {
        for source in ReaderListSource.allCases {
            #expect(CompactReaderNavigation.paneAfterListSource(source) == .publications)
        }
    }

    @Test("publication opens articles for feed lists")
    func publicationOpensArticlesForFeeds() {
        #expect(CompactReaderNavigation.paneAfterPublication(.subscribed) == .articles)
        #expect(CompactReaderNavigation.paneAfterPublication(.following) == .articles)
    }

    @Test("detail always opens reader pane")
    func detailOpensReader() {
        #expect(CompactReaderNavigation.paneAfterDetail() == .reader)
    }

    @Test("swipe from reader to articles clears detail in four-pane mode")
    func readerToArticlesClearsDetail() {
        let transition = CompactReaderNavigation.swipeTransition(
            from: .reader,
            to: .articles,
            usesArticlesPane: true
        )
        #expect(transition == CompactReaderNavigation.SwipeTransition(
            clearsReaderDetail: true,
            clearsArticleSelection: false,
            clearsFeedState: false
        ))
    }

    @Test("swipe from articles to publications clears article selection")
    func articlesToPublicationsClearsSelection() {
        let transition = CompactReaderNavigation.swipeTransition(
            from: .articles,
            to: .publications,
            usesArticlesPane: true
        )
        #expect(transition == CompactReaderNavigation.SwipeTransition(
            clearsReaderDetail: false,
            clearsArticleSelection: true,
            clearsFeedState: false
        ))
    }

    @Test("swipe to lists clears feed state")
    func listsSwipeClearsFeedState() {
        let transition = CompactReaderNavigation.swipeTransition(
            from: .reader,
            to: .lists,
            usesArticlesPane: true
        )
        #expect(transition.clearsFeedState)
    }

    @Test("three-pane list source change remaps articles pane")
    func threePaneListSourceRemapsArticles() {
        let remapped = CompactReaderNavigation.remapPaneAfterListSourceChange(
            compactPane: .articles,
            newSource: .readLater
        )
        #expect(remapped == .publications)
    }

    @Test("deferred navigation completes only when epoch is unchanged")
    func deferredNavigationEpochGate() {
        #expect(CompactReaderNavigation.shouldCompleteDeferredNavigation(requestedEpoch: 2, currentEpoch: 2))
        #expect(!CompactReaderNavigation.shouldCompleteDeferredNavigation(requestedEpoch: 2, currentEpoch: 3))
    }

    @Test("layout change normalizes articles pane in three-pane mode")
    func layoutChangeNormalizesArticlesPane() {
        let normalized = CompactReaderNavigation.normalizedPaneAfterLayoutChange(
            compactPane: .articles,
            usesArticlesPane: false
        )
        #expect(normalized == .publications)
    }
}

@Suite("ReaderPane compact pager")
struct ReaderPaneCompactPagerTests {
    @Test("uses contiguous tab tags without an articles pane")
    func threePaneTagsAreContiguous() {
        #expect(ReaderPane.lists.compactTabTag(usesArticlesPane: false) == 0)
        #expect(ReaderPane.publications.compactTabTag(usesArticlesPane: false) == 1)
        #expect(ReaderPane.reader.compactTabTag(usesArticlesPane: false) == 2)
        #expect(ReaderPane.fromCompactTabTag(2, usesArticlesPane: false) == .reader)
    }

    @Test("preserves four-pane tab tags when articles pane is shown")
    func fourPaneTagsKeepArticlesIndex() {
        #expect(ReaderPane.reader.compactTabTag(usesArticlesPane: true) == 3)
        #expect(ReaderPane.fromCompactTabTag(3, usesArticlesPane: true) == .reader)
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
