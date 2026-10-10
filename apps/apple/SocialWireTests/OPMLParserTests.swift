import Foundation
import Testing
@testable import SocialWire

@Suite("OPML import")
struct OPMLParserTests {
    @Test("parses nested outlines, normalizes URLs, and deduplicates feeds")
    func parsesNestedOutlines() throws {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><body>
          <outline text="Technology">
            <outline text="Example" xmlUrl="http://EXAMPLE.com/feed.xml#latest" htmlUrl="http://example.com" />
            <outline title="Duplicate" xmlUrl="https://example.com/feed.xml" />
          </outline>
        </body></opml>
        """

        let feeds = try OPMLParser.parse(Data(document.utf8))

        #expect(feeds.count == 1)
        #expect(feeds[0].title == "Example")
        #expect(feeds[0].feedURL == "https://example.com/feed.xml")
        #expect(feeds[0].siteURL == "https://example.com")
    }

    @Test("rejects files over two megabytes")
    func rejectsLargeFiles() {
        let data = Data(repeating: 0, count: OPMLParser.maximumBytes + 1)
        #expect(throws: OPMLParserError.fileTooLarge) {
            try OPMLParser.parse(data)
        }
    }

    @Test("rejects documents without feed outlines")
    func rejectsEmptyDocuments() {
        let document = "<opml version=\"2.0\"><body><outline text=\"Folder\" /></body></opml>"
        #expect(throws: OPMLParserError.noFeeds) {
            try OPMLParser.parse(Data(document.utf8))
        }
    }
    @Test("Private podcast OPML imports never call the public subscription writer")
    @MainActor
    func privatePodcastImport() async throws {
        let feeds = [OPMLFeed(title: "Private", feedURL: "https://example.com/feed?token=secret", siteURL: nil)]
        let show = try JSONDecoder().decode(PodcastShow.self, from: Data(#"{"id":"private","title":"Private","sourceKind":"private-rss"}"#.utf8))
        var privateRoutes = 0
        var publicWrites = 0
        let failures = await PodcastOPMLImportBatch.run(feeds, privateFeeds: true, viewer: "alice", existingFeedURLs: [], existingIDs: [show.id], currentViewer: { "alice" }, resolve: { _, isPrivate in
            #expect(isPrivate)
            privateRoutes += 1
            return show
        }, subscribe: { _ in publicWrites += 1 }, progress: { _, _ in })
        #expect(failures.isEmpty)
        #expect(privateRoutes == 1)
        #expect(publicWrites == 0)
    }

    @Test("Podcast OPML imports skip fresh duplicates and preserve partial failures")
    @MainActor
    func podcastImportPartialFailures() async throws {
        let feeds = ["existing", "good", "bad"].map { OPMLFeed(title: $0, feedURL: "https://example.com/" + $0, siteURL: nil) }
        let show = try JSONDecoder().decode(PodcastShow.self, from: Data(#"{"id":"good","title":"Good","sourceKind":"rss","feedUrl":"https://example.com/good"}"#.utf8))
        var resolved: [String] = []
        var writes = 0
        var completed: [Int] = []
        let failures = await PodcastOPMLImportBatch.run(feeds, privateFeeds: false, viewer: "alice", existingFeedURLs: [feeds[0].feedURL], existingIDs: [], currentViewer: { "alice" }, resolve: { feed, isPrivate in
            #expect(!isPrivate)
            resolved.append(feed.title)
            if feed.title == "bad" { throw SocialWireError.invalidURL }
            return show
        }, subscribe: { _ in writes += 1 }, progress: { count, total in completed.append(count); #expect(total == 3) })
        #expect(resolved == ["good", "bad"])
        #expect(writes == 1)
        #expect(completed == [1, 2, 3])
        #expect(failures.map(\.feed.title) == ["bad"])
    }

    @Test("Changing viewers during podcast resolution stops all remaining writes")
    @MainActor
    func podcastImportViewerChange() async throws {
        let feeds = ["first", "second"].map { OPMLFeed(title: $0, feedURL: "https://example.com/" + $0, siteURL: nil) }
        let show = try JSONDecoder().decode(PodcastShow.self, from: Data(#"{"id":"first","title":"First","sourceKind":"rss"}"#.utf8))
        var viewer = "alice"
        var resolutions = 0
        var writes = 0
        let failures = await PodcastOPMLImportBatch.run(feeds, privateFeeds: false, viewer: viewer, existingFeedURLs: [], existingIDs: [], currentViewer: { viewer }, resolve: { _, _ in
            resolutions += 1
            viewer = "bob"
            return show
        }, subscribe: { _ in writes += 1 }, progress: { _, _ in })
        #expect(resolutions == 1)
        #expect(writes == 0)
        #expect(failures.count == 2)
    }

    @Test("Completed OPML feeds are removed from selection while failures remain retryable")
    @MainActor
    func importSelectionAfterPartialSuccess() throws {
        let model = OPMLImportModel()
        model.load(data: Data(#"<opml><body><outline text="Good" xmlUrl="https://example.com/good"/><outline text="Bad" xmlUrl="https://example.com/bad"/></body></opml>"#.utf8), existingFeedURLs: [])
        let failed = try #require(model.feeds.first { $0.title == "Bad" })
        model.beginImport(total: 2)
        model.noteProgress(2)
        model.finishImport(failures: [OPMLImportFailure(feed: failed, message: "Retry")], successfulFeedURLs: ["https://example.com/good"])
        #expect(model.selectedFeeds.map(\.title) == ["Bad"])
        #expect(model.totalCount == 2)
        #expect(model.failures.count == 1)
    }

}
