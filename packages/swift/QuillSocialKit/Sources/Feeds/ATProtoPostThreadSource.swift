import ATProtoCore
import Foundation

public struct ATProtoPostThreadSource: PostThreadSource {
    public typealias Request = @Sendable (_ parameters: [String: String]) async throws -> Data

    private let request: Request

    public init(request: @escaping Request) {
        self.request = request
    }

    public func thread(uri: ATURI) async throws -> PostThread {
        let data = try await request([
            "uri": uri.description,
            "depth": "6",
            "parentHeight": "8",
        ])
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let focused = response.thread.timelinePost else { throw DecodingError.valueNotFound(
            TimelinePost.self,
            .init(codingPath: [], debugDescription: "The requested post is unavailable.")
        ) }

        let parents = response.thread.parentChain
        var entries = parents.enumerated().map { index, post in
            ThreadEntry(
                post: post,
                depth: index - parents.count,
                isFocused: false,
                replyingTo: index > 0 ? parents[index - 1].author : nil
            )
        }
        entries.append(ThreadEntry(
            post: focused,
            depth: 0,
            isFocused: true,
            replyingTo: parents.last?.author
        ))
        appendReplies(
            response.thread.replies ?? [],
            depth: 1,
            replyingTo: focused.author,
            to: &entries
        )
        return PostThread(entries: entries)
    }

    private func appendReplies(
        _ replies: [Node],
        depth: Int,
        replyingTo author: TimelineAuthor,
        to entries: inout [ThreadEntry]
    ) {
        for reply in replies {
            guard let post = reply.timelinePost else { continue }
            entries.append(ThreadEntry(
                post: post,
                depth: depth,
                isFocused: false,
                replyingTo: author
            ))
            appendReplies(
                reply.replies ?? [],
                depth: depth + 1,
                replyingTo: post.author,
                to: &entries
            )
        }
    }
}

private extension ATProtoPostThreadSource {
    struct Response: Decodable {
        let thread: Node
    }

    final class Node: Decodable {
        let post: Post?
        let parent: Node?
        let replies: [Node]?

        var timelinePost: TimelinePost? { post?.timelinePost }

        var parentChain: [TimelinePost] {
            guard let parent else { return [] }
            var result = parent.parentChain
            if let post = parent.timelinePost { result.append(post) }
            return result
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
        let labels: [Label]?

        var timelinePost: TimelinePost {
            TimelinePost(
                uri: uri,
                cid: cid,
                author: author.timelineAuthor,
                text: record.text,
                facets: record.facets?.map(\.timelineFacet) ?? [],
                createdAt: Self.date(record.createdAt) ?? Self.date(indexedAt) ?? .distantPast,
                replyCount: replyCount ?? 0,
                repostCount: repostCount ?? 0,
                likeCount: likeCount ?? 0,
                quoteCount: quoteCount ?? 0,
                images: record.embed?.recoveringGIFs(
                    in: embed?.timelineImages ?? [], authorDID: author.did
                ) ?? embed?.timelineImages ?? [],
                viewerLikeURI: viewer?.like,
                viewerRepostURI: viewer?.repost,
                replyRootURI: record.reply?.root.uri,
                replyRootCID: record.reply?.root.cid,
                replyParentURI: record.reply?.parent?.uri,
                quote: embed?.quotedRecord?.timelineQuote,
                labels: (labels ?? []).filter { !($0.neg ?? false) }.map(\.timelineLabel),
                video: embed?.timelineVideo,
                externalEmbed: embed?.timelineExternalEmbed
            )
        }

        static func date(_ value: String) -> Date? {
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
                return date
            }
            return try? Date.ISO8601FormatStyle().parse(value)
        }

        let viewer: Viewer?
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
            TimelineFacet(byteStart: index.byteStart, byteEnd: index.byteEnd, features: features.compactMap(\.timelineFeature))
        }
    }

    struct Index: Decodable { let byteStart: Int; let byteEnd: Int }

    struct Feature: Decodable {
        let type: String
        let did: String?
        let uri: String?
        let tag: String?
        private enum CodingKeys: String, CodingKey { case type = "$type"; case did; case uri; case tag }

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

        var timelineQuote: TimelineQuote? {
            guard let uri, let cid, let author, let value else { return nil }
            return TimelineQuote(
                uri: uri,
                cid: cid,
                author: author.timelineAuthor,
                text: value.text,
                facets: value.facets?.map(\.timelineFacet) ?? [],
                createdAt: Post.date(value.createdAt) ?? .distantPast,
                images: value.embed?.recoveringGIFs(
                    in: embeds?.flatMap(\.timelineImages) ?? [], authorDID: author.did
                ) ?? embeds?.flatMap(\.timelineImages) ?? [],
                video: embeds?.compactMap(\.timelineVideo).first,
                externalEmbed: embeds?.compactMap(\.timelineExternalEmbed).first
            )
        }
    }
}
