import Testing
@testable import SocialWire

@Suite("Publication subscription match")
struct PublicationSubscriptionMatchTests {
    private let viewerDid = "did:plc:viewer"

    @Test("viewer owns from publicationId repo")
    func viewerOwnsFromPublicationIdRepo() {
        let pub = makePublication(
            publicationId: "did:plc:viewer",
            authorDid: "did:plc:someone-else"
        )
        #expect(viewerOwnsDiscoveredPublication(pub, viewerDid: viewerDid))
    }

    @Test("viewer owns from author DID")
    func viewerOwnsFromAuthorDid() {
        let pub = makePublication(
            publicationId: "at://did:plc:other/site.standard.publication/pub1",
            authorDid: "did:plc:viewer"
        )
        #expect(viewerOwnsDiscoveredPublication(pub, viewerDid: viewerDid))
    }

    @Test("subscription match keys include alternate collection")
    func subscriptionMatchKeysIncludeAlternateCollection() {
        let pub = makePublication(
            publicationId: "at://did:plc:author/site.standard.publication/key1",
            authorDid: "did:plc:author"
        )
        let keys = publicationSubscriptionMatchKeys(for: pub)
        #expect(keys.contains("at://did:plc:author/com.standard.publication/key1"))
    }

    @Test("isSubscribedPublication does not match author DID to publication AT-URI")
    func isSubscribedPublicationDoesNotMatchAuthorDidToPublicationUri() {
        let pub = makePublication(
            publicationId: "at://did:plc:author/site.standard.publication/key1",
            authorDid: "did:plc:author"
        )
        var subscriptionKeys: Set<String> = []
        addPublicationSubscriptionLookupKeys(into: &subscriptionKeys, value: "did:plc:author")
        #expect(!isSubscribedPublication(pub, subscriptionKeys: subscriptionKeys))
    }

    @Test("following tab excludes subscribed and owned")
    func followingTabExcludesSubscribedAndOwned() {
        let owned = makePublication(publicationId: "did:plc:viewer", authorDid: viewerDid)
        let subscribed = makePublication(
            publicationId: "at://did:plc:alice/site.standard.publication/a",
            authorDid: "did:plc:alice"
        )
        let followOnly = makePublication(
            publicationId: "at://did:plc:bob/site.standard.publication/b",
            authorDid: "did:plc:bob"
        )

        var subscriptionKeys: Set<String> = []
        addPublicationSubscriptionLookupKeys(into: &subscriptionKeys, value: "did:plc:alice")

        let segmented = segmentDiscoveryPublications(
            [owned, subscribed, followOnly],
            viewerDid: viewerDid,
            subscriptionKeys: subscriptionKeys
        )

        #expect(segmented.graphSubscribed.map(\.publicationId) == [
            owned.publicationId,
            subscribed.publicationId,
        ])
        #expect(segmented.followOwnedUnsubscribed.map(\.publicationId) == [followOnly.publicationId])

        let myPubs = [owned]
        let following = filterFollowingTabPublications(
            followOwnedUnsubscribed: segmented.followOwnedUnsubscribed,
            myPublications: myPubs
        )
        #expect(following.map(\.publicationId) == [followOnly.publicationId])
    }

    private func makePublication(publicationId: String, authorDid: String) -> DiscoveredPublication {
        DiscoveredPublication(
            publicationId: publicationId,
            subscriptionPublicationId: publicationId,
            authorDid: authorDid,
            authorHandle: "handle.test",
            title: "Title",
            iconUrl: nil,
            avatarUrl: nil,
            discoveredAt: "2026-01-01T00:00:00.000Z"
        )
    }
}
