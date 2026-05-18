import XCTest
@testable import SocialWire

final class PublicationSubscriptionMatchTests: XCTestCase {
    private let viewerDid = "did:plc:viewer"

    func testViewerOwnsFromPublicationIdRepo() {
        let pub = makePublication(
            publicationId: "did:plc:viewer",
            authorDid: "did:plc:someone-else"
        )
        XCTAssertTrue(viewerOwnsDiscoveredPublication(pub, viewerDid: viewerDid))
    }

    func testViewerOwnsFromAuthorDid() {
        let pub = makePublication(
            publicationId: "at://did:plc:other/site.standard.publication/pub1",
            authorDid: "did:plc:viewer"
        )
        XCTAssertTrue(viewerOwnsDiscoveredPublication(pub, viewerDid: viewerDid))
    }

    func testSubscriptionMatchKeysIncludeAlternateCollection() {
        let pub = makePublication(
            publicationId: "at://did:plc:author/site.standard.publication/key1",
            authorDid: "did:plc:author"
        )
        let keys = publicationSubscriptionMatchKeys(for: pub)
        XCTAssertTrue(keys.contains("at://did:plc:author/com.standard.publication/key1"))
    }

    func testIsSubscribedPublicationMatchesAuthorDid() {
        let pub = makePublication(
            publicationId: "at://did:plc:author/site.standard.publication/key1",
            authorDid: "did:plc:author"
        )
        var subscriptionKeys: Set<String> = []
        addPublicationSubscriptionLookupKeys(into: &subscriptionKeys, value: "did:plc:author")
        XCTAssertTrue(isSubscribedPublication(pub, subscriptionKeys: subscriptionKeys))
    }

    func testFollowingTabExcludesSubscribedAndOwned() {
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

        XCTAssertEqual(segmented.graphSubscribed.map(\.publicationId), [
            owned.publicationId,
            subscribed.publicationId,
        ])
        XCTAssertEqual(segmented.followOwnedUnsubscribed.map(\.publicationId), [followOnly.publicationId])

        let myPubs = [owned]
        let following = filterFollowingTabPublications(
            followOwnedUnsubscribed: segmented.followOwnedUnsubscribed,
            myPublications: myPubs
        )
        XCTAssertEqual(following.map(\.publicationId), [followOnly.publicationId])
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
