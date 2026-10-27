import Foundation
import OSLog

public struct ATProtoTimelineSource: TimelineSource {
    public typealias Request = @Sendable (_ parameters: [String: String]) async throws -> Data

    private let request: Request
    private let feedURI: String?

    public init(feedURI: String? = nil, request: @escaping Request) {
        self.feedURI = feedURI
        self.request = request
    }

    public func timeline(cursor: String?, limit: Int = 50) async throws -> TimelinePage {
        var parameters = ["limit": String(min(max(limit, 1), 100))]
        if let feedURI {
            parameters["feed"] = feedURI
        }
        if let cursor {
            parameters["cursor"] = cursor
        }

        let data = try await request(parameters)
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            let path: String
            switch error {
            case let DecodingError.keyNotFound(key, context):
                path = (context.codingPath + [key]).map(\.stringValue).joined(separator: ".")
            case let DecodingError.typeMismatch(_, context),
                 let DecodingError.valueNotFound(_, context),
                 let DecodingError.dataCorrupted(context):
                path = context.codingPath.map(\.stringValue).joined(separator: ".")
            default:
                path = "unknown"
            }
            Logger(subsystem: "app.thesocialwire", category: "SocialTimeline")
                .error("Timeline response decoding failed at \(path, privacy: .public)")
            throw error
        }
        return TimelinePage(posts: response.feed.map(\.timelinePost), cursor: response.cursor)
    }
}

private extension ATProtoTimelineSource {
    struct Response: Decodable {
        let feed: [FeedItem]
        let cursor: String?
    }

    struct FeedItem: Decodable {
        let post: Post
        let reason: Reason?
        let reply: ReplyContext?

        var timelinePost: TimelinePost {
            TimelinePost(
                uri: post.uri,
                cid: post.cid,
                author: post.author.timelineAuthor,
                text: post.record.text,
                facets: post.record.facets?.map(\.timelineFacet) ?? [],
                createdAt: Self.date(post.record.createdAt) ?? Self.date(post.indexedAt) ?? .distantPast,
                replyCount: post.replyCount ?? 0,
                repostCount: post.repostCount ?? 0,
                likeCount: post.likeCount ?? 0,
                quoteCount: post.quoteCount ?? 0,
                repostedBy: reason?.by?.timelineAuthor,
                images: post.record.embed?.recoveringGIFs(
                    in: post.embed?.timelineImages ?? [], authorDID: post.author.did
                ) ?? post.embed?.timelineImages ?? [],
                viewerLikeURI: post.viewer?.like,
                viewerRepostURI: post.viewer?.repost,
                replyRootURI: post.record.reply?.root.uri,
                replyRootCID: post.record.reply?.root.cid,
                replyParentURI: post.record.reply?.parent?.uri,
                replyingTo: reply?.parent.author?.timelineAuthor,
                quote: post.embed?.quotedRecord?.timelineQuote,
                labels: (post.labels ?? []).filter { !($0.neg ?? false) }.map(\.timelineLabel),
                video: post.embed?.timelineVideo,
                externalEmbed: post.embed?.timelineExternalEmbed
            )
        }

        static func date(_ value: String) -> Date? {
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
                return date
            }
            return try? Date.ISO8601FormatStyle().parse(value)
        }
    }

    struct Post: Decodable {
        let uri: String
        let cid: String
        let author: Author
        let record: Record
        let replyCount: Int?
        let repostCount: Int?
        let likeCount: Int?
        let quoteCount: Int?
        let indexedAt: String
        let embed: Embed?
        let viewer: Viewer?
        let labels: [Label]?
    }

    struct Record: Decodable {
        let text: String
        let createdAt: String
        let reply: Reply?
        let facets: [Facet]?
        let embed: OriginalGIFEmbed?
    }

    struct Reply: Decodable {
        let root: Reference
        let parent: Reference?
    }

    struct Reference: Decodable {
        let uri: String
        let cid: String
    }

    struct Label: Decodable {
        let src: String
        let val: String
        let neg: Bool?

        var timelineLabel: TimelineLabel {
            TimelineLabel(source: src, value: val, isNegation: neg ?? false)
        }
    }

    struct Viewer: Decodable {
        let like: String?
        let repost: String?
    }

    struct Reason: Decodable {
        // reasonPin has no author; only reasonRepost carries by.
        let by: Author?
    }

    struct ReplyContext: Decodable {
        let parent: ReplyPost
    }

    struct ReplyPost: Decodable {
        let author: Author?

        private enum CodingKeys: String, CodingKey { case type = "$type"; case author }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decodeIfPresent(String.self, forKey: .type)
            // blockedPost.author is a blockedAuthor, not a profileViewBasic.
            // It intentionally contains no handle or other public profile fields.
            if type == "app.bsky.feed.defs#blockedPost" || type == "app.bsky.feed.defs#notFoundPost" {
                author = nil
            } else {
                author = try container.decodeIfPresent(Author.self, forKey: .author)
            }
        }
    }

    struct Embed: Decodable {
        let images: [Image]?
        let items: [GalleryImage]?
        let media: Media?
        let record: RecordEmbed?
        let external: External?
        let thumbnail: URL?
        let playlist: URL?
        let alt: String?
        let aspectRatio: Image.AspectRatio?

        var timelineVideo: TimelineVideo? {
            guard let playlist = playlist ?? media?.playlist,
                  playlist.scheme?.lowercased() == "https", playlist.host != nil else { return nil }
            let ratio = aspectRatio ?? media?.aspectRatio
            return TimelineVideo(playlistURL: playlist, thumbnailURL: thumbnail ?? media?.thumbnail,
                                 altText: alt ?? media?.alt ?? "", width: ratio?.width, height: ratio?.height)
        }

        var timelineImages: [TimelineImage] {
            if let images = images ?? media?.images {
                return images.map(\.timelineImage)
            }
            if let items = items ?? media?.items {
                return items.map(\.timelineImage)
            }
            return []
        }

        var timelineExternalEmbed: TimelineExternalEmbed? {
            guard let external = external ?? media?.external,
                  let uri = external.uri,
                  let title = external.title else { return nil }
            return TimelineExternalEmbed(
                uri: uri,
                title: title,
                description: external.description ?? "",
                thumbnailURL: external.thumb
            )
        }

        var quotedRecord: QuotedRecord? { record?.record }
    }

    struct Media: Decodable {
        let images: [Image]?
        let items: [GalleryImage]?
        let external: External?
        let thumbnail: URL?
        let playlist: URL?
        let alt: String?
        let aspectRatio: Image.AspectRatio?
    }

    struct External: Decodable {
        let uri: URL?
        let thumb: URL?
        let title: String?
        let description: String?
    }

    struct Facet: Decodable {
        let index: Index
        let features: [Feature]

        var timelineFacet: TimelineFacet {
            TimelineFacet(
                byteStart: index.byteStart,
                byteEnd: index.byteEnd,
                features: features.compactMap(\.timelineFeature)
            )
        }
    }

    struct Index: Decodable { let byteStart: Int; let byteEnd: Int }

    struct Feature: Decodable {
        let type: String
        let did: String?
        let uri: String?
        let tag: String?

        private enum CodingKeys: String, CodingKey {
            case type = "$type"; case did; case uri; case tag
        }

        var timelineFeature: TimelineFacet.Feature? {
            switch type {
            case "app.bsky.richtext.facet#mention": did.map(TimelineFacet.Feature.mention)
            case "app.bsky.richtext.facet#link": uri.map(TimelineFacet.Feature.link)
            case "app.bsky.richtext.facet#tag": tag.map(TimelineFacet.Feature.tag)
            default: nil
            }
        }
    }

    struct RecordEmbed: Decodable {
        let record: QuotedRecord?

        private enum CodingKeys: String, CodingKey {
            case record
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.record) {
                record = try container.decodeIfPresent(QuotedRecord.self, forKey: .record)
            } else {
                record = try QuotedRecord(from: decoder)
            }
        }
    }

    struct Image: Decodable {
        struct AspectRatio: Decodable {
            let width: Int
            let height: Int
        }

        let thumb: URL
        let fullsize: URL
        let alt: String
        let aspectRatio: AspectRatio?

        var timelineImage: TimelineImage {
            TimelineImage(
                thumbnailURL: thumb,
                fullsizeURL: fullsize,
                altText: alt,
                width: aspectRatio?.width,
                height: aspectRatio?.height
            )
        }
    }

    struct GalleryImage: Decodable {
        let thumbnail: URL
        let fullsize: URL
        let alt: String
        let aspectRatio: Image.AspectRatio?

        var timelineImage: TimelineImage {
            TimelineImage(
                thumbnailURL: thumbnail,
                fullsizeURL: fullsize,
                altText: alt,
                width: aspectRatio?.width,
                height: aspectRatio?.height
            )
        }
    }

    struct QuotedRecord: Decodable {
        let uri: String?
        let cid: String?
        let author: Author?
        let value: Record?
        let embeds: [Embed]?

        private enum CodingKeys: String, CodingKey {
            case uri, cid, author, value, embeds
        }

        private struct RecordType: Decodable {
            let type: String?
            private enum CodingKeys: String, CodingKey { case type = "$type" }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uri = try container.decodeIfPresent(String.self, forKey: .uri)
            cid = try container.decodeIfPresent(String.self, forKey: .cid)
            author = try container.decodeIfPresent(Author.self, forKey: .author)
            embeds = try container.decodeIfPresent([Embed].self, forKey: .embeds)
            let type = try container.decodeIfPresent(RecordType.self, forKey: .value)?.type
            // Record embeds can reference any collection, including feed generators and
            // lists. Those records have no post text or creation date.
            if type == nil || type == "app.bsky.feed.post" {
                value = try container.decodeIfPresent(Record.self, forKey: .value)
            } else {
                value = nil
            }
        }

        var timelineQuote: TimelineQuote? {
            guard let uri, let cid, let author, let value else { return nil }
            return TimelineQuote(
                uri: uri,
                cid: cid,
                author: author.timelineAuthor,
                text: value.text,
                facets: value.facets?.map(\.timelineFacet) ?? [],
                createdAt: FeedItem.date(value.createdAt) ?? .distantPast,
                images: value.embed?.recoveringGIFs(
                    in: embeds?.flatMap(\.timelineImages) ?? [], authorDID: author.did
                ) ?? embeds?.flatMap(\.timelineImages) ?? [],
                video: embeds?.compactMap(\.timelineVideo).first,
                externalEmbed: embeds?.compactMap(\.timelineExternalEmbed).first
            )
        }
    }

    struct Author: Decodable {
        let did: String
        let handle: String
        let displayName: String?
        let avatar: URL?
        let labels: [Label]?
        let verification: VerificationState?
        let status: StatusView?

        var timelineAuthor: TimelineAuthor {
            TimelineAuthor(
                did: did,
                handle: handle,
                displayName: displayName,
                avatarURL: avatar,
                labels: (labels ?? []).filter { !($0.neg ?? false) }.map(\.timelineLabel),
                verifications: (verification?.verifications ?? [])
                    .filter(\.isValid)
                    .map(\.timelineVerification),
                isLiveStreaming: status?.isLiveStreaming ?? false
            )
        }
    }

    struct StatusView: Decodable {
        let status: String
        let isActive: Bool?
        let isDisabled: Bool?
        let expiresAt: String?

        var isLiveStreaming: Bool {
            guard status == "app.bsky.actor.status#live",
                  isActive != false,
                  isDisabled != true else { return false }
            guard let expiresAt else { return true }
            return (try? Date(expiresAt, strategy: .iso8601)) ?? .distantPast > .now
        }
    }

    struct VerificationState: Decodable {
        let verifications: [Verification]
    }

    struct Verification: Decodable {
        let issuer: String
        let issuerDisplayName: String?
        let issuerHandle: String?
        let uri: String
        let isValid: Bool

        var timelineVerification: TimelineVerification {
            TimelineVerification(
                issuer: issuer,
                issuerDisplayName: issuerDisplayName,
                issuerHandle: issuerHandle,
                uri: uri,
                isValid: isValid
            )
        }
    }
}
