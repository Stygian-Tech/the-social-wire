import Foundation
import Testing
@testable import SocialWire

@Suite("Unified feed selection")
struct UnifiedFeedSelectionTests {
    @Test("selection cases remain exclusive")
    func selectionCasesRemainDistinct() {
        let selections: Set<FeedSelection> = [
            .topLevel(.wire),
            .topLevel(.subscribed),
            .folder("folder-one"),
            .publication("at://did:plc:example/site.standard.publication/main"),
            .savedSource(.readLater, "site:example.com"),
        ]

        #expect(selections.count == 5)
        #expect(FeedSelection.topLevel(.following).topLevelSource == .following)
        #expect(FeedSelection.folder("folder-one").topLevelSource == nil)
    }

    @Test("mark-all-read follows the exclusive feed selection")
    func markAllReadScopeMatchesSelection() {
        #expect(
            ReaderMarkReadScope.selectedFeed(.topLevel(.subscribed))
                == .list(.subscribed)
        )
        #expect(
            ReaderMarkReadScope.selectedFeed(.folder("product"))
                == .folder(folderRkey: "product")
        )
        #expect(
            ReaderMarkReadScope.selectedFeed(.publication("at://did:plc:alice/site.standard.publication/main"))
                == .publication(publicationId: "at://did:plc:alice/site.standard.publication/main")
        )
    }

    @Test("top-level read context menus exclude saved feeds")
    func topLevelReadContextMenuAvailability() {
        #expect(ReaderListSource.subscribed.supportsMarkAllReadContextMenu)
        #expect(ReaderListSource.following.supportsMarkAllReadContextMenu)
        #expect(!ReaderListSource.readLater.supportsMarkAllReadContextMenu)
        #expect(!ReaderListSource.archive.supportsMarkAllReadContextMenu)
        #expect(!ReaderListSource.wire.supportsMarkAllReadContextMenu)
        #expect(ReaderMarkReadScope.selectedFeed(.topLevel(.wire)) == .unavailable)
    }

    @Test("preference decoding defaults additive fields and preserves order")
    func preferenceDefaultsAndFallback() {
        let defaults = ReaderFeedPreferences(record: nil)
        #expect(defaults.visibleFeeds == ReaderListSource.preferenceCases)
        #expect(defaults.feedsWithUnreadCounts == ReaderListSource.preferenceCases)
        let ignoresWire = ReaderFeedPreferences(
            visibleFeeds: [.wire, .following],
            feedsWithUnreadCounts: [.wire, .following]
        )
        #expect(ignoresWire.visibleFeeds == [.following])
        #expect(ignoresWire.feedsWithUnreadCounts == [.following])

        let record = PreferencesRecord(
            type: "app.thesocialwire.preferences",
            readLaterService: nil,
            readLaterConnections: nil,
            visibleFeeds: ["following", "readLater"],
            showTopLevelFeedUnreadCounts: false,
            feedsWithUnreadCounts: nil,
            rssArticleOpenMode: nil,
            createdAt: "2026-07-26T00:00:00Z",
            updatedAt: "2026-07-26T00:00:00Z"
        )
        let preferences = ReaderFeedPreferences(record: record)
        #expect(preferences.visibleFeeds == [.following, .readLater])
        #expect(preferences.feedsWithUnreadCounts.isEmpty)

        let perFeedRecord = PreferencesRecord(
            type: "app.thesocialwire.preferences",
            readLaterService: nil,
            readLaterConnections: nil,
            visibleFeeds: ["following", "readLater"],
            showTopLevelFeedUnreadCounts: true,
            feedsWithUnreadCounts: ["following", "archive"],
            rssArticleOpenMode: nil,
            createdAt: "2026-07-26T00:00:00Z",
            updatedAt: "2026-07-26T00:00:00Z"
        )
        let perFeedPreferences = ReaderFeedPreferences(record: perFeedRecord)
        #expect(perFeedPreferences.feedsWithUnreadCounts == [.following])
    }
}

@Suite("PublicationUnreadCountLookup")
struct PublicationUnreadCountLookupTests {
    @Test("top-level sums count each publication once")
    func aggregateSumsDeduplicateMembers() {
        let publication = DiscoveredPublication(
            publicationId: "at://did:plc:abc/site.standard.publication/main",
            subscriptionPublicationId: nil,
            authorDid: "did:plc:abc",
            authorHandle: "",
            title: "Example",
            iconUrl: nil,
            avatarUrl: nil,
            discoveredAt: "2026-07-26T00:00:00Z"
        )
        #expect(sumUnreadCount(for: [publication, publication]) { _ in 4 } == 4)
    }

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

@MainActor
@Suite("SidebarUnreadController")
struct SidebarUnreadControllerTests {
    @Test("displayCount memoizes until read revision bumps")
    func displayCountMemoizes() {
        let controller = SidebarUnreadController()
        controller.unreadCountsByPublicationId = ["pub-a": 2]
        let first = controller.displayCount(
            publicationId: "pub-a",
            readAtByEntryId: [:],
            coordinator: nil
        )
        let second = controller.displayCount(
            publicationId: "pub-a",
            readAtByEntryId: [:],
            coordinator: nil
        )
        #expect(first == 2)
        #expect(second == 2)
        controller.bumpReadRevision()
        let third = controller.displayCount(
            publicationId: "pub-a",
            readAtByEntryId: ["entry-1": Date()],
            coordinator: nil
        )
        #expect(third == 2)
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

    @Test("raises a cleared baseline when newly cached unread entries arrive")
    func cachedUnreadRaisesClearedBaseline() {
        let count = EffectiveUnreadCount.effectivePublicationUnreadCount(
            serverCount: 0,
            cachedEntryIds: ["new-entry"],
            isEntryRead: { _ in false }
        )
        #expect(count == 1)
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
    @Test("list source opens the first content pane")
    func listSourceOpensFirstContentPane() {
        #expect(CompactReaderNavigation.paneAfterListSource(.wire) == .articles)
        #expect(CompactReaderNavigation.paneAfterListSource(.subscribed) == .articles)
        #expect(CompactReaderNavigation.paneAfterListSource(.following) == .articles)
        #expect(CompactReaderNavigation.paneAfterListSource(.readLater) == .publications)
        #expect(CompactReaderNavigation.paneAfterListSource(.archive) == .publications)
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
            navigationShape: .publicationFeed
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
            navigationShape: .publicationFeed
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
            navigationShape: .publicationFeed
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
            navigationShape: .savedLinks
        )
        #expect(normalized == .publications)
        #expect(CompactReaderNavigation.normalizedPaneAfterLayoutChange(
            compactPane: .publications,
            navigationShape: .wire
        ) == .articles)
    }
}

@Suite("ReaderPane compact pager")
struct ReaderPaneCompactPagerTests {
    @Test("uses contiguous tab tags without an articles pane")
    func threePaneTagsAreContiguous() {
        #expect(ReaderPane.lists.compactTabTag(navigationShape: .savedLinks) == 0)
        #expect(ReaderPane.publications.compactTabTag(navigationShape: .savedLinks) == 1)
        #expect(ReaderPane.reader.compactTabTag(navigationShape: .savedLinks) == 2)
        #expect(ReaderPane.fromCompactTabTag(2, navigationShape: .savedLinks) == .reader)
    }

    @Test("preserves four-pane tab tags when articles pane is shown")
    func fourPaneTagsKeepArticlesIndex() {
        #expect(ReaderPane.reader.compactTabTag(navigationShape: .publicationFeed) == 3)
        #expect(ReaderPane.fromCompactTabTag(3, navigationShape: .publicationFeed) == .reader)
    }

    @Test("The Wire uses contiguous lists articles reader tags")
    func wireTagsAreContiguous() {
        #expect(ReaderPane.lists.compactTabTag(navigationShape: .wire) == 0)
        #expect(ReaderPane.articles.compactTabTag(navigationShape: .wire) == 1)
        #expect(ReaderPane.reader.compactTabTag(navigationShape: .wire) == 2)
        #expect(ReaderPane.publications.compactTabTag(navigationShape: .wire) == nil)
        #expect(ReaderPane.fromCompactTabTag(1, navigationShape: .wire) == .articles)
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
