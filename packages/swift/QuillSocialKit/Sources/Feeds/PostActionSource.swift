import Foundation

public struct PostImageAttachment: Sendable {
    public let data: Data
    public let mimeType: String
    public let altText: String
    public let width: Int
    public let height: Int

    public init(
        data: Data,
        mimeType: String,
        altText: String = "",
        width: Int = 1,
        height: Int = 1
    ) {
        self.data = data
        self.mimeType = mimeType
        self.altText = altText
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

public struct PostExternalAttachment: Sendable {
    public let uri: URL
    public let title: String
    public let description: String
    public let thumbnailData: Data?
    public let thumbnailMimeType: String?

    public init(
        uri: URL,
        title: String,
        description: String,
        thumbnailData: Data? = nil,
        thumbnailMimeType: String? = nil
    ) {
        self.uri = uri
        self.title = title
        self.description = description
        self.thumbnailData = thumbnailData
        self.thumbnailMimeType = thumbnailMimeType
    }
}

public struct PostThreadDraft: Sendable {
    public let text: String
    public let mentions: [String: String]
    public let images: [PostImageAttachment]
    public let external: PostExternalAttachment?

    public init(
        text: String,
        mentions: [String: String],
        images: [PostImageAttachment] = [],
        external: PostExternalAttachment? = nil
    ) {
        self.text = text
        self.mentions = mentions
        self.images = images
        self.external = external
    }
}

public protocol PostActionSource: Sendable {
    func like(_ post: TimelinePost) async throws -> String
    func unlike(recordURI: String) async throws
    func repost(_ post: TimelinePost) async throws -> String
    func undoRepost(recordURI: String) async throws
    func reply(text: String, mentions: [String: String], to post: TimelinePost) async throws
    func quote(text: String, mentions: [String: String], post: TimelinePost) async throws
    func createPost(text: String, mentions: [String: String], images: [PostImageAttachment]) async throws
    func createThread(_ drafts: [PostThreadDraft]) async throws
    func createReplyThread(_ drafts: [PostThreadDraft], to post: TimelinePost) async throws
    func createQuoteThread(_ drafts: [PostThreadDraft], quoting post: TimelinePost) async throws
}

public extension PostActionSource {
    func createPost(text: String, mentions: [String: String], images: [PostImageAttachment] = []) async throws {
        throw URLError(.unsupportedURL)
    }
    func createThread(_ drafts: [PostThreadDraft]) async throws {
        guard drafts.count == 1, let draft = drafts.first else { throw URLError(.unsupportedURL) }
        try await createPost(text: draft.text, mentions: draft.mentions, images: draft.images)
    }
    func createReplyThread(_ drafts: [PostThreadDraft], to post: TimelinePost) async throws {
        guard drafts.count == 1, let draft = drafts.first, draft.images.isEmpty else {
            throw URLError(.unsupportedURL)
        }
        try await reply(text: draft.text, mentions: draft.mentions, to: post)
    }
    func createQuoteThread(_ drafts: [PostThreadDraft], quoting post: TimelinePost) async throws {
        guard drafts.count == 1, let draft = drafts.first, draft.images.isEmpty else {
            throw URLError(.unsupportedURL)
        }
        try await quote(text: draft.text, mentions: draft.mentions, post: post)
    }
    func reply(text: String, to post: TimelinePost) async throws {
        try await reply(text: text, mentions: [:], to: post)
    }

    func quote(text: String, post: TimelinePost) async throws {
        try await quote(text: text, mentions: [:], post: post)
    }
}
