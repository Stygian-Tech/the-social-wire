import Foundation

struct SocialFeedResponse: Decodable, Sendable {
    let feed: [SocialFeedItemDTO]
    let cursor: String?
}

struct SocialPostSearchResponse: Decodable, Sendable {
    let posts: [SocialPostDTO]
    let cursor: String?
}

struct SocialActorSearchResponse: Decodable, Sendable {
    let actors: [SocialAuthorDTO]
    let cursor: String?
}

struct SocialFeedItemDTO: Decodable, Sendable {
    let post: SocialPostDTO
    let reason: SocialReasonDTO?
    let reply: SocialReplyContextDTO?

    var socialPost: SocialPost {
        post.makeSocialPost(repostedBy: reason?.by.socialAuthor, replyingTo: reply?.parent.author.socialAuthor)
    }
}

struct SocialPostDTO: Decodable, Sendable {
    let uri: String
    let cid: String
    let author: SocialAuthorDTO
    let record: SocialPostRecordDTO
    let replyCount: Int?
    let repostCount: Int?
    let likeCount: Int?
    let quoteCount: Int?
    let indexedAt: String
    let embed: SocialEmbedDTO?
    let viewer: SocialPostViewerDTO?
    let labels: [SocialLabelDTO]?

    var socialPost: SocialPost { makeSocialPost(repostedBy: nil, replyingTo: nil) }

    func makeSocialPost(repostedBy: SocialAuthor?, replyingTo: SocialAuthor?) -> SocialPost {
        SocialPost(
            uri: uri,
            cid: cid,
            author: author.socialAuthor,
            text: record.text,
            createdAt: SocialDate.parse(record.createdAt) ?? SocialDate.parse(indexedAt) ?? .distantPast,
            replyCount: replyCount ?? 0,
            repostCount: repostCount ?? 0,
            likeCount: likeCount ?? 0,
            quoteCount: quoteCount ?? 0,
            viewerLikeURI: viewer?.like,
            viewerRepostURI: viewer?.repost,
            replyRoot: record.reply?.root.socialReference,
            replyParent: record.reply?.parent.socialReference,
            replyingTo: replyingTo,
            repostedBy: repostedBy,
            embed: embed?.socialEmbed ?? SocialEmbed(),
            labels: (labels ?? []).filter { $0.neg != true }.map(\.val)
        )
    }
}

struct SocialAuthorDTO: Decodable, Sendable {
    let did: String
    let handle: String
    let displayName: String?
    let avatar: URL?

    var socialAuthor: SocialAuthor {
        SocialAuthor(did: did, handle: handle, displayName: displayName, avatar: avatar)
    }
}

struct SocialPostRecordDTO: Decodable, Sendable {
    let text: String
    let createdAt: String
    let reply: SocialReplyDTO?
}

struct SocialReplyDTO: Decodable, Sendable {
    let root: SocialReferenceDTO
    let parent: SocialReferenceDTO
}

struct SocialReferenceDTO: Codable, Sendable {
    let uri: String
    let cid: String
    var socialReference: SocialPostReference { SocialPostReference(uri: uri, cid: cid) }
}

struct SocialPostViewerDTO: Decodable, Sendable {
    let like: String?
    let repost: String?
}

struct SocialLabelDTO: Decodable, Sendable {
    let val: String
    let neg: Bool?
}

struct SocialReasonDTO: Decodable, Sendable { let by: SocialAuthorDTO }
struct SocialReplyContextDTO: Decodable, Sendable { let parent: SocialReplyPostDTO }
struct SocialReplyPostDTO: Decodable, Sendable { let author: SocialAuthorDTO }

struct SocialEmbedDTO: Decodable, Sendable {
    let images: [SocialImageDTO]?
    let media: SocialMediaDTO?
    let external: SocialExternalDTO?
    let record: SocialRecordContainerDTO?
    let playlist: URL?
    let thumbnail: URL?
    let alt: String?

    var socialEmbed: SocialEmbed {
        SocialEmbed(
            images: (images ?? media?.images ?? []).map(\.socialImage),
            external: (external ?? media?.external)?.socialExternal,
            video: (playlist ?? media?.playlist).map {
                SocialVideo(playlist: $0, thumbnail: thumbnail ?? media?.thumbnail, alt: alt ?? media?.alt ?? "")
            },
            quote: record?.record?.socialQuote
        )
    }
}

struct SocialMediaDTO: Decodable, Sendable {
    let images: [SocialImageDTO]?
    let external: SocialExternalDTO?
    let playlist: URL?
    let thumbnail: URL?
    let alt: String?
}

struct SocialImageDTO: Decodable, Sendable {
    let thumb: URL
    let fullsize: URL
    let alt: String
    let aspectRatio: SocialAspectRatioDTO?
    var socialImage: SocialImage {
        SocialImage(thumbnail: thumb, fullsize: fullsize, alt: alt, width: aspectRatio?.width, height: aspectRatio?.height)
    }
}

struct SocialAspectRatioDTO: Decodable, Sendable { let width: Int; let height: Int }

struct SocialExternalDTO: Decodable, Sendable {
    let uri: URL
    let title: String
    let description: String
    let thumb: URL?
    var socialExternal: SocialExternalEmbed {
        SocialExternalEmbed(uri: uri, title: title, description: description, thumbnail: thumb)
    }
}

struct SocialRecordContainerDTO: Decodable, Sendable { let record: SocialQuotedPostDTO? }

struct SocialQuotedPostDTO: Decodable, Sendable {
    let uri: String
    let cid: String
    let author: SocialAuthorDTO
    let value: SocialPostRecordDTO?
    let record: SocialPostRecordDTO?
    let indexedAt: String?
    var socialQuote: SocialQuotedPost {
        let body = value ?? record
        return SocialQuotedPost(
            uri: uri,
            cid: cid,
            author: author.socialAuthor,
            text: body?.text ?? "",
            createdAt: body.flatMap { SocialDate.parse($0.createdAt) } ?? indexedAt.flatMap(SocialDate.parse) ?? .distantPast
        )
    }
}

struct SocialProfileDTO: Decodable, Sendable {
    let did: String
    let handle: String
    let displayName: String?
    let description: String?
    let avatar: URL?
    let banner: URL?
    let followersCount: Int?
    let followsCount: Int?
    let postsCount: Int?
    let viewer: Viewer?

    struct Viewer: Decodable, Sendable {
        let muted: Bool?
        let blockedBy: Bool?
        let blocking: String?
        let following: String?
        let followedBy: String?
    }

    var socialProfile: SocialProfile {
        SocialProfile(
            author: SocialAuthor(did: did, handle: handle, displayName: displayName, avatar: avatar),
            description: description ?? "",
            banner: banner,
            followersCount: followersCount ?? 0,
            followsCount: followsCount ?? 0,
            postsCount: postsCount ?? 0,
            followsViewer: viewer?.followedBy != nil,
            viewerFollowingURI: viewer?.following,
            viewerMuted: viewer?.muted ?? false,
            viewerBlockedBy: viewer?.blockedBy ?? false,
            viewerBlockingURI: viewer?.blocking
        )
    }
}

struct SocialThreadResponse: Decodable, Sendable { let thread: SocialThreadNodeDTO }

final class SocialThreadNodeDTO: Decodable, Sendable {
    let post: SocialPostDTO?
    let parent: SocialThreadNodeDTO?
    let replies: [SocialThreadNodeDTO]?

    var flattenedPosts: [SocialPost] {
        var result = parent?.flattenedPosts ?? []
        if let post { result.append(post.socialPost) }
        result.append(contentsOf: (replies ?? []).flatMap(\.flattenedPosts))
        return result
    }
}

struct SocialNotificationResponse: Decodable, Sendable {
    let notifications: [SocialNotificationDTO]
    let cursor: String?
}

struct SocialNotificationDTO: Decodable, Sendable {
    let uri: String
    let cid: String
    let author: SocialAuthorDTO
    let reason: String
    let reasonSubject: String?
    let record: SocialPostRecordDTO?
    let isRead: Bool
    let indexedAt: String

    var socialNotification: SocialNotification {
        let post = record.map {
            SocialPost(uri: uri, cid: cid, author: author.socialAuthor, text: $0.text,
                       createdAt: SocialDate.parse($0.createdAt) ?? .distantPast,
                       replyCount: 0, repostCount: 0, likeCount: 0, quoteCount: 0,
                       viewerLikeURI: nil, viewerRepostURI: nil,
                       replyRoot: $0.reply?.root.socialReference, replyParent: $0.reply?.parent.socialReference,
                       replyingTo: nil, repostedBy: nil, embed: SocialEmbed(), labels: [])
        }
        return SocialNotification(uri: uri, cid: cid, author: author.socialAuthor, reason: reason,
                                  reasonSubject: reasonSubject, indexedAt: SocialDate.parse(indexedAt) ?? .distantPast,
                                  isRead: isRead, post: post)
    }
}

struct SocialUnreadCountResponse: Decodable, Sendable { let count: Int }

struct SocialConversationResponse: Decodable, Sendable {
    let convos: [SocialConversationDTO]
    let cursor: String?
}

struct SocialConversationDTO: Decodable, Sendable {
    let id: String
    let members: [SocialAuthorDTO]
    let lastMessage: SocialMessageDTO?
    let unreadCount: Int
    let muted: Bool
    let status: String?
    var socialConversation: SocialConversation {
        SocialConversation(id: id, members: members.map(\.socialAuthor), lastMessage: lastMessage?.socialMessage,
                           unreadCount: unreadCount, muted: muted, status: status)
    }
}

struct SocialMessageResponse: Decodable, Sendable {
    let messages: [SocialMessageDTO]
    let cursor: String?
}

struct SocialSingleMessageResponse: Decodable, Sendable {
    let message: SocialMessageDTO
}

struct SocialMessageDTO: Decodable, Sendable {
    let id: String?
    let rev: String?
    let sender: SocialMessageSenderDTO?
    let text: String?
    let sentAt: String?
    let replyTo: SocialMessageReferenceDTO?
    let reactions: [SocialMessageReactionDTO]?
    var socialMessage: SocialMessage? {
        guard let id, let sender, let text, let sentAt, let date = SocialDate.parse(sentAt) else { return nil }
        return SocialMessage(id: id, revision: rev, senderDID: sender.did, text: text, sentAt: date,
                             replyTo: replyTo.map { .init(id: $0.id, revision: $0.rev) },
                             reactions: (reactions ?? []).map(\.socialReaction))
    }
}

struct SocialMessageSenderDTO: Decodable, Sendable { let did: String }
struct SocialMessageReferenceDTO: Decodable, Sendable { let id: String; let rev: String? }
struct SocialMessageReactionDTO: Decodable, Sendable {
    let sender: SocialMessageSenderDTO
    let value: String
    let createdAt: String?
    var socialReaction: SocialMessageReaction {
        SocialMessageReaction(senderDID: sender.did, value: value, createdAt: createdAt.flatMap(SocialDate.parse))
    }
}

enum SocialDate {
    static func parse(_ value: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) { return date }
        return try? Date.ISO8601FormatStyle().parse(value)
    }
}

struct SocialFeedDirectoryResponse: Decodable, Sendable { let feeds: [SocialFeedSummaryDTO]; let cursor: String? }
struct SocialFeedSummaryDTO: Decodable, Sendable {
    let uri: String; let cid: String; let did: String; let creator: SocialAuthorDTO
    let displayName: String; let description: String?; let avatar: URL?; let likeCount: Int?
    var socialFeed: SocialFeedSummary { .init(uri: uri, cid: cid, did: did, creator: creator.socialAuthor, displayName: displayName, description: description ?? "", avatar: avatar, likeCount: likeCount ?? 0) }
}

struct SocialListResponse: Decodable, Sendable { let lists: [SocialListSummaryDTO]; let cursor: String? }
struct SocialListSummaryDTO: Decodable, Sendable {
    let uri: String; let cid: String; let name: String; let description: String?; let avatar: URL?; let creator: SocialAuthorDTO; let indexedAt: String?; let listItemCount: Int?
    var socialList: SocialListSummary { .init(uri: uri, cid: cid, name: name, description: description ?? "", avatar: avatar, creator: creator.socialAuthor, itemCount: listItemCount ?? 0) }
}

struct SocialBookmarkResponse: Decodable, Sendable { let bookmarks: [SocialBookmarkDTO]; let cursor: String? }
struct SocialBookmarkDTO: Decodable, Sendable { let item: SocialPostDTO }
