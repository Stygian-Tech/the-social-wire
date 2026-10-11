import Foundation
import Testing
@testable import SocialWire

struct PodcastSubscriptionMatchTests {
    @Test("Unsubscribe matches Podcast records and preserves News records for the same feed")
    func feedCategoryIsolation() throws {
        let show = try JSONDecoder().decode(PodcastShow.self, from: Data(#"{"id":"show","title":"Show","sourceKind":"rss","feedUrl":"https://example.com/feed.xml"}"#.utf8))
        for category in ["podcast", " Podcast ", "PODCAST"] {
            #expect(PodcastSubscriptionMatch.matches(.object(["category": .string(category), "feedUrl": .string(show.feedUrl!)]), show: show))
        }
        for category in ["", "news", "publication"] {
            #expect(!PodcastSubscriptionMatch.matches(.object(["category": .string(category), "feedUrl": .string(show.feedUrl!)]), show: show))
        }
        #expect(!PodcastSubscriptionMatch.matches(.object(["feedUrl": .string(show.feedUrl!)]), show: show))
        #expect(!PodcastSubscriptionMatch.matches(.object(["category": .string("podcast"), "feedUrl": .string("https://other.example/feed.xml")]), show: show))
    }

    @Test("Legacy subscriptions require an explicit supported native Podcast source")
    func legacyProtocolClassification() {
        for collection in ["org.atpodcasting.podcast", "place.pod.show", "live.voxport.podcast.series"] {
            let record: JSONValue = .object(["sourceType": .string("atproto.collection"), "externalRef": .string("at://did:plc:show/\(collection)/key")])
            #expect(PodcastSubscriptionMatch.isPodcast(record))
        }
        #expect(!PodcastSubscriptionMatch.isPodcast(.object(["sourceType": .string("atproto.collection"), "externalRef": .string("at://did:plc:publication/site.standard.publication/key")])))
        #expect(!PodcastSubscriptionMatch.isPodcast(.object(["category": .string("news"), "sourceType": .string("atproto.collection"), "externalRef": .string("at://did:plc:show/place.pod.show/key")])))
        #expect(!PodcastSubscriptionMatch.isPodcast(.object(["sourceType": .string("rss"), "externalRef": .string("at://did:plc:show/place.pod.show/key")])))
        #expect(!PodcastSubscriptionMatch.isPodcast(.object(["sourceType": .string("atproto.collection"), "externalRef": .string("at://did:plc:show/place.pod.show/key/extra")])))
    }
}
