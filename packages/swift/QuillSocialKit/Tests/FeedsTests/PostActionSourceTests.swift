import Foundation
import Testing
@testable import Feeds

@Suite("Post Actions")
struct PostActionSourceTests {
    private actor Recorder {
        var nsid: String?
        var body: Data?

        func record(nsid: String, body: Data) {
            self.nsid = nsid
            self.body = body
        }
    }

    private actor SequenceRecorder {
        var bodies: [Data] = []

        func append(_ body: Data) -> Int {
            bodies.append(body)
            return bodies.count
        }
    }

    @Test("Like creates an authenticated repository record")
    func createsLikeRecord() async throws {
        let recorder = Recorder()
        let source = ATProtoPostActionSource(
            sessionDID: { "did:plc:viewer" },
            procedure: { nsid, body in
                await recorder.record(nsid: nsid, body: body)
                return Data(#"{"uri":"at://did:plc:viewer/app.bsky.feed.like/1"}"#.utf8)
            }
        )
        let post = TimelinePost(
            uri: "at://did:plc:alice/app.bsky.feed.post/1",
            cid: "bafypost",
            author: TimelineAuthor(did: "did:plc:alice", handle: "alice.test"),
            text: "Hello",
            createdAt: .now
        )

        let uri = try await source.like(post)
        let body = try #require(await recorder.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let record = try #require(object["record"] as? [String: Any])

        #expect(uri.hasSuffix("/1"))
        #expect(await recorder.nsid == "com.atproto.repo.createRecord")
        #expect(object["repo"] as? String == "did:plc:viewer")
        #expect(object["collection"] as? String == "app.bsky.feed.like")
        #expect(record["$type"] as? String == "app.bsky.feed.like")
    }

    @Test("Quote post creates a record embed")
    func createsQuotePostRecord() async throws {
        let recorder = Recorder()
        let source = ATProtoPostActionSource(
            sessionDID: { "did:plc:viewer" },
            procedure: { nsid, body in
                await recorder.record(nsid: nsid, body: body)
                return Data(#"{"uri":"at://did:plc:viewer/app.bsky.feed.post/quote"}"#.utf8)
            }
        )
        let post = TimelinePost(
            uri: "at://did:plc:alice/app.bsky.feed.post/1",
            cid: "bafypost",
            author: TimelineAuthor(did: "did:plc:alice", handle: "alice.test"),
            text: "Hello",
            createdAt: .now
        )

        try await source.quote(
            text: "Hi @alice.test 👋",
            mentions: ["alice.test": "did:plc:alice"],
            post: post
        )
        let body = try #require(await recorder.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let record = try #require(object["record"] as? [String: Any])
        let embed = try #require(record["embed"] as? [String: Any])
        let reference = try #require(embed["record"] as? [String: Any])

        #expect(object["collection"] as? String == "app.bsky.feed.post")
        #expect(record["$type"] as? String == "app.bsky.feed.post")
        #expect(record["text"] as? String == "Hi @alice.test 👋")
        let facets = try #require(record["facets"] as? [[String: Any]])
        let index = try #require(facets.first?["index"] as? [String: Any])
        let features = try #require(facets.first?["features"] as? [[String: Any]])
        #expect(index["byteStart"] as? Int == 3)
        #expect(index["byteEnd"] as? Int == 14)
        #expect(features.first?["did"] as? String == "did:plc:alice")
        #expect(embed["$type"] as? String == "app.bsky.embed.record")
        #expect(reference["uri"] as? String == post.uri)
        #expect(reference["cid"] as? String == post.cid)
    }

    @Test("Post uploads images and creates an image embed")
    func createsPostWithImageEmbed() async throws {
        let recorder = Recorder()
        let source = ATProtoPostActionSource(
            sessionDID: { "did:plc:viewer" },
            procedure: { nsid, body in
                await recorder.record(nsid: nsid, body: body)
                return Data(#"{"uri":"at://did:plc:viewer/app.bsky.feed.post/1"}"#.utf8)
            },
            blobUpload: { data, mimeType in
                #expect(data == Data([1, 2, 3]))
                #expect(mimeType == "image/jpeg")
                return Data(
                    #"{"blob":{"$type":"blob","ref":{"$link":"bafyimage"},"mimeType":"image/jpeg","size":3}}"#.utf8
                )
            }
        )

        try await source.createPost(
            text: "A photo",
            mentions: [:],
            images: [PostImageAttachment(
                data: Data([1, 2, 3]),
                mimeType: "image/jpeg",
                altText: "Test image",
                width: 1_200,
                height: 800
            )]
        )

        let body = try #require(await recorder.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let record = try #require(object["record"] as? [String: Any])
        let embed = try #require(record["embed"] as? [String: Any])
        let images = try #require(embed["images"] as? [[String: Any]])
        let image = try #require(images.first)
        let blob = try #require(image["image"] as? [String: Any])
        let reference = try #require(blob["ref"] as? [String: Any])

        #expect(embed["$type"] as? String == "app.bsky.embed.images")
        #expect(image["alt"] as? String == "Test image")
        let aspectRatio = try #require(image["aspectRatio"] as? [String: Any])
        #expect(aspectRatio["width"] as? Int == 1_200)
        #expect(aspectRatio["height"] as? Int == 800)
        #expect(reference["$link"] as? String == "bafyimage")
    }

    @Test("Post uploads up to ten images and creates a gallery embed")
    func createsPostWithGalleryEmbed() async throws {
        let recorder = Recorder()
        let source = ATProtoPostActionSource(
            sessionDID: { "did:plc:viewer" },
            procedure: { nsid, body in
                await recorder.record(nsid: nsid, body: body)
                return Data(#"{"uri":"at://did:plc:viewer/app.bsky.feed.post/gallery"}"#.utf8)
            },
            blobUpload: { data, mimeType in
                #expect(mimeType == "image/jpeg")
                return Data(
                    """
                    {"blob":{"$type":"blob","ref":{"$link":"bafyimage\(data.first ?? 0)"},"mimeType":"image/jpeg","size":1}}
                    """.utf8
                )
            }
        )
        let attachments = (0..<11).map {
            PostImageAttachment(
                data: Data([UInt8($0)]),
                mimeType: "image/jpeg",
                altText: "Image \($0)",
                width: 1_600,
                height: 900
            )
        }

        try await source.createPost(text: "A gallery", mentions: [:], images: attachments)

        let body = try #require(await recorder.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let record = try #require(object["record"] as? [String: Any])
        let embed = try #require(record["embed"] as? [String: Any])
        let items = try #require(embed["items"] as? [[String: Any]])

        #expect(embed["$type"] as? String == "app.bsky.embed.gallery")
        #expect(items.count == 10)
        #expect(items.allSatisfy { $0["$type"] as? String == "app.bsky.embed.gallery#image" })
        #expect(items.allSatisfy {
            let ratio = $0["aspectRatio"] as? [String: Any]
            return ratio?["width"] as? Int == 1_600 && ratio?["height"] as? Int == 900
        })
        #expect(items.last?["alt"] as? String == "Image 9")
    }

    @Test("Thread drafts are posted as a reply chain")
    func createsThreadReplyChain() async throws {
        let recorder = SequenceRecorder()
        let source = ATProtoPostActionSource(
            sessionDID: { "did:plc:viewer" },
            procedure: { _, body in
                let index = await recorder.append(body)
                return Data(
                    """
                    {"uri":"at://did:plc:viewer/app.bsky.feed.post/\(index)","cid":"bafy\(index)"}
                    """.utf8
                )
            }
        )

        try await source.createThread([
            PostThreadDraft(text: "First", mentions: [:]),
            PostThreadDraft(text: "Second", mentions: [:]),
            PostThreadDraft(text: "Third", mentions: [:]),
        ])

        let bodies = await recorder.bodies
        #expect(bodies.count == 3)
        let secondObject = try #require(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        let secondRecord = try #require(secondObject["record"] as? [String: Any])
        let secondReply = try #require(secondRecord["reply"] as? [String: Any])
        let secondRoot = try #require(secondReply["root"] as? [String: Any])
        let secondParent = try #require(secondReply["parent"] as? [String: Any])
        let thirdObject = try #require(JSONSerialization.jsonObject(with: bodies[2]) as? [String: Any])
        let thirdRecord = try #require(thirdObject["record"] as? [String: Any])
        let thirdReply = try #require(thirdRecord["reply"] as? [String: Any])
        let thirdRoot = try #require(thirdReply["root"] as? [String: Any])
        let thirdParent = try #require(thirdReply["parent"] as? [String: Any])

        #expect(secondRoot["uri"] as? String == "at://did:plc:viewer/app.bsky.feed.post/1")
        #expect(secondParent["cid"] as? String == "bafy1")
        #expect(thirdRoot["cid"] as? String == "bafy1")
        #expect(thirdParent["uri"] as? String == "at://did:plc:viewer/app.bsky.feed.post/2")
    }

    @Test("Thread draft creates an external link embed")
    func createsExternalLinkEmbed() async throws {
        let recorder = Recorder()
        let source = ATProtoPostActionSource(
            sessionDID: { "did:plc:viewer" },
            procedure: { nsid, body in
                await recorder.record(nsid: nsid, body: body)
                return Data(#"{"uri":"at://did:plc:viewer/app.bsky.feed.post/link","cid":"bafylink"}"#.utf8)
            }
        )

        try await source.createThread([
            PostThreadDraft(
                text: "Read https://example.com/article",
                mentions: [:],
                external: PostExternalAttachment(
                    uri: try #require(URL(string: "https://example.com/article")),
                    title: "Example Article",
                    description: "An example description"
                )
            ),
        ])

        let body = try #require(await recorder.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let record = try #require(object["record"] as? [String: Any])
        let embed = try #require(record["embed"] as? [String: Any])
        let external = try #require(embed["external"] as? [String: Any])
        let facets = try #require(record["facets"] as? [[String: Any]])

        #expect(embed["$type"] as? String == "app.bsky.embed.external")
        #expect(external["uri"] as? String == "https://example.com/article")
        #expect(external["title"] as? String == "Example Article")
        #expect(external["description"] as? String == "An example description")
        #expect(facets.count == 1)
    }

    @Test("Reply thread starts beneath the referenced post")
    func createsReplyThread() async throws {
        let recorder = Recorder()
        let source = ATProtoPostActionSource(
            sessionDID: { "did:plc:viewer" },
            procedure: { nsid, body in
                await recorder.record(nsid: nsid, body: body)
                return Data(#"{"uri":"at://did:plc:viewer/app.bsky.feed.post/reply","cid":"bafyreply"}"#.utf8)
            }
        )
        let parent = TimelinePost(
            uri: "at://did:plc:alice/app.bsky.feed.post/parent",
            cid: "bafyparent",
            author: TimelineAuthor(did: "did:plc:alice", handle: "alice.test"),
            text: "Parent",
            createdAt: .now
        )

        try await source.createReplyThread(
            [PostThreadDraft(text: "Reply", mentions: [:])],
            to: parent
        )

        let body = try #require(await recorder.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let record = try #require(object["record"] as? [String: Any])
        let reply = try #require(record["reply"] as? [String: Any])
        let root = try #require(reply["root"] as? [String: Any])
        let replyParent = try #require(reply["parent"] as? [String: Any])

        #expect(root["uri"] as? String == parent.uri)
        #expect(replyParent["cid"] as? String == parent.cid)
    }

    @Test("Quote thread combines the quoted record with a gallery")
    func createsQuoteThreadWithGallery() async throws {
        let recorder = Recorder()
        let source = ATProtoPostActionSource(
            sessionDID: { "did:plc:viewer" },
            procedure: { nsid, body in
                await recorder.record(nsid: nsid, body: body)
                return Data(#"{"uri":"at://did:plc:viewer/app.bsky.feed.post/quote","cid":"bafyquote"}"#.utf8)
            },
            blobUpload: { _, _ in
                Data(#"{"blob":{"$type":"blob","ref":{"$link":"bafyimage"},"mimeType":"image/jpeg","size":1}}"#.utf8)
            }
        )
        let quoted = TimelinePost(
            uri: "at://did:plc:alice/app.bsky.feed.post/quoted",
            cid: "bafyquoted",
            author: TimelineAuthor(did: "did:plc:alice", handle: "alice.test"),
            text: "Quoted",
            createdAt: .now
        )
        let images = (0..<5).map {
            PostImageAttachment(data: Data([UInt8($0)]), mimeType: "image/jpeg", altText: "Image \($0)")
        }

        try await source.createQuoteThread(
            [PostThreadDraft(text: "Comment", mentions: [:], images: images)],
            quoting: quoted
        )

        let body = try #require(await recorder.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let record = try #require(object["record"] as? [String: Any])
        let embed = try #require(record["embed"] as? [String: Any])
        let quotedRecord = try #require(embed["record"] as? [String: Any])
        let reference = try #require(quotedRecord["record"] as? [String: Any])
        let media = try #require(embed["media"] as? [String: Any])
        let items = try #require(media["items"] as? [[String: Any]])

        #expect(embed["$type"] as? String == "app.bsky.embed.recordWithMedia")
        #expect(reference["uri"] as? String == quoted.uri)
        #expect(media["$type"] as? String == "app.bsky.embed.gallery")
        #expect(items.count == 5)
    }

    @Test("Markdown links become native Bluesky link facets")
    func createsMarkdownLinkFacet() throws {
        let result = PostRichTextEncoder.encode(
            "Read [Quill](https://quill.example) with `code`",
            mentions: [:]
        )

        #expect(result.text == "Read Quill with `code`")
        let facet = try #require(result.facets.first)
        #expect(facet.index.byteStart == 5)
        #expect(facet.index.byteEnd == 10)

        let data = try JSONEncoder().encode(facet)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try #require(object["features"] as? [[String: Any]])
        #expect(features.first?["$type"] as? String == "app.bsky.richtext.facet#link")
        #expect(features.first?["uri"] as? String == "https://quill.example")
    }

    @Test("Hashtags and cashtags become native tag facets")
    func createsHashtagAndCashtagFacets() throws {
        let result = PostRichTextEncoder.encode(
            "Building #Swift while watching $AAPL",
            mentions: [:]
        )

        #expect(result.facets.count == 2)
        let encoded = try result.facets.map { facet -> ([String: Any], String) in
            let data = try JSONEncoder().encode(facet)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let features = try #require(object["features"] as? [[String: Any]])
            let feature = try #require(features.first)
            return (feature, feature["tag"] as? String ?? "")
        }

        #expect(encoded.allSatisfy { $0.0["$type"] as? String == "app.bsky.richtext.facet#tag" })
        #expect(encoded.map(\.1) == ["Swift", "$AAPL"])
        #expect(result.facets[0].index.byteStart == 9)
        #expect(result.facets[0].index.byteEnd == 15)
        #expect(result.facets[1].index.byteStart == 31)
        #expect(result.facets[1].index.byteEnd == 36)
    }

    @Test("Dotted share-class cashtags retain their full tag and byte range")
    func createsDottedCashtagFacets() throws {
        let result = PostRichTextEncoder.encode("👋 #Swift $BRK.B and $BF.A.", mentions: [:])
        let tags = try result.facets.map { facet -> String in
            let data = try JSONEncoder().encode(facet)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let features = try #require(object["features"] as? [[String: Any]])
            return try #require(features.first?["tag"] as? String)
        }
        #expect(tags == ["Swift", "$BRK.B", "$BF.A"])
        #expect(result.facets[1].index.byteStart == 12)
        #expect(result.facets[1].index.byteEnd == 18)
        #expect(result.facets[2].index.byteStart == 23)
        #expect(result.facets[2].index.byteEnd == 28)
    }
}
