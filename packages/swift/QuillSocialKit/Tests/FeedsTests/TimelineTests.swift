import Foundation
import Testing
@testable import Feeds

@Suite("Timeline")
struct TimelineTests {
    private actor PagingSource: TimelineSource {
        let first: TimelinePost
        let second: TimelinePost

        init(first: TimelinePost, second: TimelinePost) {
            self.first = first
            self.second = second
        }

        func timeline(cursor: String?, limit: Int) async throws -> TimelinePage {
            cursor == nil
                ? TimelinePage(posts: [first], cursor: "next")
                : TimelinePage(posts: [first, second], cursor: nil)
        }
    }

    @Test("Decodes subscribed labelers for App View requests")
    func decodesAcceptedLabelers() throws {
        let data = Data("""
        {
          "preferences": [{
            "$type": "app.bsky.actor.defs#labelersPref",
            "labelers": [
              { "did": "did:plc:one" },
              { "did": "did:web:two.example" },
              { "did": "did:plc:one" }
            ]
          }]
        }
        """.utf8)

        let labelers = try AcceptedLabelers(preferencesData: data)

        #expect(labelers.dids == [
            "did:plc:ar7c4by46qjdydhdevvrndac",
            "did:plc:one",
            "did:web:two.example",
        ])
    }

    @Test("Can exclude Bluesky moderation from App View requests")
    func excludesBlueskyModeration() throws {
        let data = Data("""
        {
          "preferences": [{
            "$type": "app.bsky.actor.defs#labelersPref",
            "labelers": [
              { "did": "did:plc:one" },
              { "did": "did:web:two.example" }
            ]
          }]
        }
        """.utf8)

        let labelers = try AcceptedLabelers(
            preferencesData: data,
            includesBluesky: false
        )

        #expect(labelers.dids == [
            "did:plc:one",
            "did:web:two.example",
        ])
    }

    @Test("Decodes an App View timeline page")
    func decodesTimeline() async throws {
        let data = Data("""
        {
          "cursor": "next-page",
          "feed": [{
            "post": {
              "uri": "at://did:plc:alice/app.bsky.feed.post/1",
              "cid": "bafypost",
              "author": {
                "did": "did:plc:alice",
                "handle": "alice.test",
                "displayName": "Alice",
                "avatar": "https://cdn.test/alice.jpg",
                "labels": [{
                  "src": "did:plc:account-labeler",
                  "uri": "did:plc:alice",
                  "val": "community",
                  "cts": "2026-09-21T12:35:00Z"
                }],
                "verification": {
                  "verifiedStatus": "valid",
                  "trustedVerifierStatus": "none",
                  "verifications": [{
                    "issuer": "did:plc:verifier",
                    "issuerDisplayName": "Verifier",
                    "issuerHandle": "verifier.test",
                    "uri": "at://did:plc:verifier/app.bsky.graph.verification/1",
                    "isValid": true,
                    "createdAt": "2026-09-21T12:00:00Z"
                  }]
                },
                "status": {
                  "status": "app.bsky.actor.status#live",
                  "record": {},
                  "isActive": true,
                  "isDisabled": false,
                  "expiresAt": "2099-09-21T13:00:00Z"
                }
              },
              "record": {
                "$type": "app.bsky.feed.post",
                "text": "Hello from Bluesky",
                "createdAt": "2026-09-21T12:34:56.123Z"
              },
              "replyCount": 2,
              "repostCount": 3,
              "likeCount": 5,
              "quoteCount": 1,
              "indexedAt": "2026-09-21T12:34:57.000Z",
              "labels": [{
                "src": "did:plc:labeler",
                "uri": "at://did:plc:alice/app.bsky.feed.post/1",
                "val": "spam",
                "cts": "2026-09-21T12:35:00Z"
              }],
              "embed": {
                "$type": "app.bsky.embed.images#view",
                "images": [{
                  "thumb": "https://cdn.test/thumb.jpg",
                  "fullsize": "https://cdn.test/full.jpg",
                  "alt": "A blue sky",
                  "aspectRatio": { "width": 1600, "height": 900 }
                }]
              }
            }
          }]
        }
        """.utf8)

        let source = ATProtoTimelineSource { parameters in
            #expect(parameters["limit"] == "50")
            #expect(parameters["cursor"] == nil)
            return data
        }

        let page = try await source.timeline(cursor: nil, limit: 50)

        #expect(page.cursor == "next-page")
        #expect(page.posts.count == 1)
        #expect(page.posts[0].author.displayName == "Alice")
        #expect(page.posts[0].author.labels.first?.value == "community")
        #expect(page.posts[0].author.verifications.first?.issuer == "did:plc:verifier")
        #expect(page.posts[0].author.isLiveStreaming)
        #expect(page.posts[0].text == "Hello from Bluesky")
        #expect(page.posts[0].likeCount == 5)
        #expect(page.posts[0].images.first?.altText == "A blue sky")
        #expect(page.posts[0].images.first?.width == 1600)
        #expect(page.posts[0].labels.first?.source == "did:plc:labeler")
        #expect(page.posts[0].labels.first?.value == "spam")
    }

    @Test("Decodes gallery images from an App View timeline")
    func decodesGalleryImages() async throws {
        let data = Data("""
        {
          "feed": [{
            "post": {
              "uri": "at://did:plc:alice/app.bsky.feed.post/gallery",
              "cid": "bafygallery",
              "author": { "did": "did:plc:alice", "handle": "alice.test" },
              "record": { "text": "Gallery", "createdAt": "2026-09-21T12:34:56Z" },
              "indexedAt": "2026-09-21T12:34:57Z",
              "embed": {
                "$type": "app.bsky.embed.gallery#view",
                "items": [
                  {
                    "$type": "app.bsky.embed.gallery#viewImage",
                    "thumbnail": "https://cdn.test/one-thumb.jpg",
                    "fullsize": "https://cdn.test/one.jpg",
                    "alt": "One",
                    "aspectRatio": { "width": 4, "height": 3 }
                  },
                  {
                    "$type": "app.bsky.embed.gallery#viewImage",
                    "thumbnail": "https://cdn.test/two-thumb.jpg",
                    "fullsize": "https://cdn.test/two.jpg",
                    "alt": "Two"
                  }
                ]
              }
            }
          }]
        }
        """.utf8)

        let source = ATProtoTimelineSource { _ in data }
        let post = try #require(await source.timeline(cursor: nil, limit: 50).posts.first)

        #expect(post.images.count == 2)
        #expect(post.images.first?.altText == "One")
        #expect(post.images.first?.width == 4)
        #expect(post.images.last?.altText == "Two")
    }

    @Test("Decodes the parent author for a reply")
    func decodesReplyContext() async throws {
        let data = Data("""
        {
          "feed": [{
            "post": {
              "uri": "at://did:plc:alice/app.bsky.feed.post/reply",
              "cid": "bafypost",
              "author": { "did": "did:plc:alice", "handle": "alice.test" },
              "record": {
                "text": "A reply",
                "createdAt": "2026-09-21T12:34:56Z",
                "reply": {
                  "root": { "uri": "at://did:plc:bob/app.bsky.feed.post/root", "cid": "rootcid" },
                  "parent": { "uri": "at://did:plc:bob/app.bsky.feed.post/root", "cid": "rootcid" }
                }
              },
              "indexedAt": "2026-09-21T12:34:57Z"
            },
            "reply": {
              "root": {
                "uri": "at://did:plc:bob/app.bsky.feed.post/root",
                "cid": "rootcid",
                "author": { "did": "did:plc:bob", "handle": "bob.test" },
                "record": { "text": "Root", "createdAt": "2026-09-21T12:00:00Z" },
                "indexedAt": "2026-09-21T12:00:01Z"
              },
              "parent": {
                "uri": "at://did:plc:bob/app.bsky.feed.post/root",
                "cid": "rootcid",
                "author": { "did": "did:plc:bob", "handle": "bob.test", "displayName": "Bob" },
                "record": { "text": "Root", "createdAt": "2026-09-21T12:00:00Z" },
                "indexedAt": "2026-09-21T12:00:01Z"
              }
            }
          }]
        }
        """.utf8)

        let source = ATProtoTimelineSource { _ in data }
        let post = try #require(await source.timeline(cursor: nil, limit: 50).posts.first)

        #expect(post.replyingTo?.handle == "bob.test")
        #expect(post.replyingTo?.displayName == "Bob")
    }

    @Test("Decodes a quote post")
    func decodesQuotePost() async throws {
        let data = Data("""
        {
          "feed": [{
            "post": {
              "uri": "at://did:plc:alice/app.bsky.feed.post/1",
              "cid": "bafypost",
              "author": { "did": "did:plc:alice", "handle": "alice.test" },
              "record": { "text": "Worth sharing", "createdAt": "2026-09-21T12:34:56Z" },
              "indexedAt": "2026-09-21T12:34:57Z",
              "embed": {
                "$type": "app.bsky.embed.record#view",
                "record": {
                  "$type": "app.bsky.embed.record#viewRecord",
                  "uri": "at://did:plc:bob/app.bsky.feed.post/quoted",
                  "cid": "bafyquoted",
                  "author": { "did": "did:plc:bob", "handle": "bob.test", "displayName": "Bob" },
                  "value": { "text": "Quoted text", "createdAt": "2026-09-20T10:00:00Z" },
                  "embeds": [{
                    "$type": "app.bsky.embed.images#view",
                    "images": [{
                      "thumb": "https://cdn.test/quote-thumb.jpg",
                      "fullsize": "https://cdn.test/quote-full.jpg",
                      "alt": "Quoted image"
                    }]
                  }]
                }
              }
            }
          }]
        }
        """.utf8)

        let source = ATProtoTimelineSource { _ in data }
        let post = try #require(await source.timeline(cursor: nil, limit: 50).posts.first)

        #expect(post.quote?.author.displayName == "Bob")
        #expect(post.quote?.text == "Quoted text")
        #expect(post.quote?.images.first?.altText == "Quoted image")
    }

    @MainActor
    @Test("Pagination removes overlapping posts")
    func paginationDeduplicates() async {
        let first = TimelinePost(
            uri: "at://did:plc:alice/app.bsky.feed.post/1",
            cid: "one",
            author: TimelineAuthor(did: "did:plc:alice", handle: "alice.test"),
            text: "One",
            createdAt: .now
        )
        let second = TimelinePost(
            uri: "at://did:plc:alice/app.bsky.feed.post/2",
            cid: "two",
            author: TimelineAuthor(did: "did:plc:alice", handle: "alice.test"),
            text: "Two",
            createdAt: .now
        )
        let source = PagingSource(first: first, second: second)
        let model = TimelineModel(source: source)

        await model.load()
        await model.loadMore(after: first)

        #expect(model.posts.map(\.id) == [first.id, second.id])
    }

    @Test("Standard site metadata is attached before a timeline page is returned")
    func enrichesStandardSiteEmbedsBeforeDelivery() async throws {
        let articleURL = try #require(URL(string: "https://publication.example/article"))
        let publicationURL = try #require(URL(string: "https://publication.example"))
        let first = TimelinePost(
            uri: "at://did:plc:alice/app.bsky.feed.post/1",
            cid: "one",
            author: TimelineAuthor(did: "did:plc:alice", handle: "alice.test"),
            text: "Article",
            createdAt: .now,
            externalEmbed: TimelineExternalEmbed(
                uri: articleURL,
                title: "A complete article",
                description: "Description"
            )
        )
        let second = TimelinePost(
            uri: "at://did:plc:alice/app.bsky.feed.post/2",
            cid: "two",
            author: TimelineAuthor(did: "did:plc:alice", handle: "alice.test"),
            text: "Second",
            createdAt: .now
        )
        let source = StandardSiteEnrichedTimelineSource(
            base: PagingSource(first: first, second: second),
            resolver: { url in
                guard url == articleURL else { return nil }
                return StandardSiteEmbedMetadata(
                    publicationName: "Publication",
                    publicationURL: publicationURL,
                    publicationURI: "at://did:plc:publication/site.standard.publication/self",
                    logoURL: nil,
                    authorName: "Alice",
                    authorAvatarURL: nil
                )
            }
        )

        let page = try await source.timeline(cursor: nil, limit: 50)

        #expect(page.posts.map(\.id) == [first.id])
        #expect(page.posts.first?.externalEmbed?.standardSite?.publicationName == "Publication")
        #expect(page.posts.first?.externalEmbed?.standardSite?.authorName == "Alice")
    }

    @Test("Standard site viewer actions preserve document metadata")
    func attachesStandardSiteViewerActions() throws {
        let publicationURL = try #require(URL(string: "https://publication.example"))
        let metadata = StandardSiteEmbedMetadata(
            publicationName: "Publication",
            publicationURL: publicationURL,
            publicationURI: "at://did:plc:publication/site.standard.publication/self",
            documentURI: "at://did:plc:publication/site.standard.document/article",
            logoURL: nil,
            authorName: "Alice",
            authorAvatarURL: nil
        )
        let subscription = "at://did:plc:viewer/site.standard.graph.subscription/one"
        let recommend = "at://did:plc:viewer/site.standard.graph.recommend/two"

        let updated = metadata
            .attachingViewerSubscription(subscription)
            .attachingViewerRecommend(recommend)

        #expect(updated.documentURI == metadata.documentURI)
        #expect(updated.viewerSubscriptionURI == subscription)
        #expect(updated.viewerRecommendURI == recommend)
    }
}
