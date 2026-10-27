import ATProtoCore
import Foundation

public struct ATProtoPostActionSource: PostActionSource {
    public typealias SessionDID = @Sendable () async throws -> String
    public typealias Procedure = @Sendable (_ nsid: String, _ body: Data) async throws -> Data
    public typealias BlobUpload = @Sendable (_ data: Data, _ mimeType: String) async throws -> Data

    private let sessionDID: SessionDID
    private let procedure: Procedure
    private let blobUpload: BlobUpload?

    public init(
        sessionDID: @escaping SessionDID,
        procedure: @escaping Procedure,
        blobUpload: BlobUpload? = nil
    ) {
        self.sessionDID = sessionDID
        self.procedure = procedure
        self.blobUpload = blobUpload
    }

    public func like(_ post: TimelinePost) async throws -> String {
        try await create(
            collection: "app.bsky.feed.like",
            record: SubjectRecord(type: "app.bsky.feed.like", post: post)
        )
    }

    public func unlike(recordURI: String) async throws {
        try await delete(recordURI: recordURI, collection: "app.bsky.feed.like")
    }

    public func repost(_ post: TimelinePost) async throws -> String {
        try await create(
            collection: "app.bsky.feed.repost",
            record: SubjectRecord(type: "app.bsky.feed.repost", post: post)
        )
    }

    public func undoRepost(recordURI: String) async throws {
        try await delete(recordURI: recordURI, collection: "app.bsky.feed.repost")
    }

    public func reply(text: String, mentions: [String: String], to post: TimelinePost) async throws {
        let richText = PostRichTextEncoder.encode(text, mentions: mentions)
        let parent = Reference(uri: post.uri, cid: post.cid)
        let root = Reference(uri: post.replyRootURI ?? post.uri, cid: post.replyRootCID ?? post.cid)
        let record = ReplyRecord(
            text: richText.text,
            facets: richText.facets,
            createdAt: Date(),
            reply: Reply(root: root, parent: parent)
        )
        _ = try await create(collection: "app.bsky.feed.post", record: record)
    }

    public func quote(text: String, mentions: [String: String], post: TimelinePost) async throws {
        let richText = PostRichTextEncoder.encode(text, mentions: mentions)
        let embed = QuoteEmbed(record: Reference(uri: post.uri, cid: post.cid))
        let record = QuoteRecord(
            text: richText.text,
            facets: richText.facets,
            createdAt: Date(),
            embed: embed
        )
        _ = try await create(collection: "app.bsky.feed.post", record: record)
    }

    public func createPost(
        text: String,
        mentions: [String: String],
        images: [PostImageAttachment]
    ) async throws {
        let richText = PostRichTextEncoder.encode(text, mentions: mentions)
        var uploadedImages: [ImageEmbed.Image] = []
        if !images.isEmpty {
            guard let blobUpload else { throw URLError(.unsupportedURL) }
            for image in images.prefix(10) {
                let response = try await blobUpload(image.data, image.mimeType)
                let blob = try JSONDecoder().decode(BlobUploadResponse.self, from: response).blob
                uploadedImages.append(ImageEmbed.Image(
                    image: blob,
                    alt: image.altText,
                    aspectRatio: AspectRatio(width: image.width, height: image.height)
                ))
            }
        }
        let embed: MediaEmbed? = if uploadedImages.isEmpty {
            nil
        } else if uploadedImages.count <= 4 {
            .images(ImageEmbed(images: uploadedImages))
        } else {
            .gallery(GalleryEmbed(items: uploadedImages.map(GalleryEmbed.Image.init)))
        }
        let record = PostRecord(
            text: richText.text,
            facets: richText.facets,
            createdAt: Date(),
            embed: embed.map(PostEmbed.media)
        )
        _ = try await create(collection: "app.bsky.feed.post", record: record)
    }

    public func createThread(_ drafts: [PostThreadDraft]) async throws {
        try await createThread(drafts, context: .post)
    }

    public func createReplyThread(_ drafts: [PostThreadDraft], to post: TimelinePost) async throws {
        try await createThread(drafts, context: .reply(post))
    }

    public func createQuoteThread(_ drafts: [PostThreadDraft], quoting post: TimelinePost) async throws {
        try await createThread(drafts, context: .quote(post))
    }

    private func createThread(_ drafts: [PostThreadDraft], context: ThreadContext) async throws {
        guard !drafts.isEmpty else { return }
        var root: Reference?
        var parent: Reference?
        if case .reply(let post) = context {
            root = Reference(uri: post.replyRootURI ?? post.uri, cid: post.replyRootCID ?? post.cid)
            parent = Reference(uri: post.uri, cid: post.cid)
        }

        var publishedCount = 0
        for (index, draft) in drafts.enumerated() {
            var writeDispatched = false
            do {
                let richText = PostRichTextEncoder.encode(draft.text, mentions: draft.mentions)
                let uploadedImages = try await uploadImages(draft.images)
                let imageMedia = mediaEmbed(for: uploadedImages)
                let external: ExternalEmbed? = if imageMedia == nil, let attachment = draft.external {
                    try await externalEmbed(for: attachment)
                } else { nil }
                let media = imageMedia ?? external.map(MediaEmbed.external)
                let embed: PostEmbed? = if index == 0, case .quote(let post) = context {
                    quoteEmbed(for: post, media: media)
                } else {
                    media.map(PostEmbed.media)
                }
                let record = PostRecord(
                    text: richText.text,
                    facets: richText.facets,
                    createdAt: Date(),
                    embed: embed,
                    reply: root.flatMap { root in parent.map { Reply(root: root, parent: $0) } }
                )
                writeDispatched = true
                let response = try await createResponse(collection: "app.bsky.feed.post", record: record)
                guard let cid = response.cid else { throw URLError(.badServerResponse) }
                let reference = Reference(uri: response.uri, cid: cid)
                root = root ?? reference
                parent = reference
                publishedCount += 1
            } catch {
                throw PostThreadPublicationFailure(
                    publishedCount: publishedCount,
                    rootURI: root?.uri, rootCID: root?.cid,
                    parentURI: parent?.uri, parentCID: parent?.cid,
                    currentDraftOutcomeUncertain: writeDispatched,
                    underlyingError: error
                )
            }
        }
    }

    private func quoteEmbed(for post: TimelinePost, media: MediaEmbed?) -> PostEmbed {
        let quote = QuoteEmbed(record: Reference(uri: post.uri, cid: post.cid))
        if let media {
            return .recordWithMedia(RecordWithMediaEmbed(record: quote, media: media))
        } else {
            return .quote(quote)
        }
    }

    private func uploadImages(_ images: [PostImageAttachment]) async throws -> [ImageEmbed.Image] {
        guard !images.isEmpty else { return [] }
        guard let blobUpload else { throw URLError(.unsupportedURL) }
        var uploadedImages: [ImageEmbed.Image] = []
        for image in images.prefix(10) {
            let response = try await blobUpload(image.data, image.mimeType)
            let blob = try JSONDecoder().decode(BlobUploadResponse.self, from: response).blob
            uploadedImages.append(ImageEmbed.Image(
                image: blob,
                alt: image.altText,
                aspectRatio: AspectRatio(width: image.width, height: image.height)
            ))
        }
        return uploadedImages
    }

    private func mediaEmbed(for images: [ImageEmbed.Image]) -> MediaEmbed? {
        if images.isEmpty {
            nil
        } else if images.count <= 4 {
            .images(ImageEmbed(images: images))
        } else {
            .gallery(GalleryEmbed(items: images.map(GalleryEmbed.Image.init)))
        }
    }

    private func externalEmbed(for attachment: PostExternalAttachment) async throws -> ExternalEmbed {
        let thumbnail: Blob?
        if let data = attachment.thumbnailData,
           let mimeType = attachment.thumbnailMimeType,
           let blobUpload {
            let response = try await blobUpload(data, mimeType)
            thumbnail = try JSONDecoder().decode(BlobUploadResponse.self, from: response).blob
        } else {
            thumbnail = nil
        }
        return ExternalEmbed(
            external: ExternalEmbed.External(
                uri: attachment.uri,
                title: attachment.title,
                description: attachment.description,
                thumbnail: thumbnail
            )
        )
    }

    private func create<Record: Encodable>(collection: String, record: Record) async throws -> String {
        try await createResponse(collection: collection, record: record).uri
    }

    private func createResponse<Record: Encodable>(collection: String, record: Record) async throws -> CreateResponse {
        let body = try JSONEncoder.atProto.encode(CreateRecord(repo: try await sessionDID(), collection: collection, record: record))
        let response = try await procedure("com.atproto.repo.createRecord", body)
        return try JSONDecoder().decode(CreateResponse.self, from: response)
    }

    private func delete(recordURI: String, collection: String) async throws {
        let uri = try ATURI(recordURI)
        guard let recordKey = uri.recordKey else { throw URLError(.badURL) }
        let body = try JSONEncoder().encode(DeleteRecord(
            repo: try await sessionDID(),
            collection: collection,
            rkey: recordKey.rawValue
        ))
        _ = try await procedure("com.atproto.repo.deleteRecord", body)
    }

}

private extension ATProtoPostActionSource {
    enum ThreadContext {
        case post
        case reply(TimelinePost)
        case quote(TimelinePost)
    }
    struct Reference: Codable { let uri: String; let cid: String }
    struct Reply: Codable { let root: Reference; let parent: Reference }
    struct SubjectRecord: Encodable {
        let type: String
        let subject: Reference
        let createdAt = Date()
        init(type: String, post: TimelinePost) {
            self.type = type
            subject = Reference(uri: post.uri, cid: post.cid)
        }
        enum CodingKeys: String, CodingKey { case type = "$type", subject, createdAt }
    }
    struct ReplyRecord: Encodable {
        let type = "app.bsky.feed.post"
        let text: String
        let facets: [PostRichTextEncoder.Facet]
        let createdAt: Date
        let reply: Reply
        enum CodingKeys: String, CodingKey { case type = "$type", text, facets, createdAt, reply }
    }
    struct QuoteEmbed: Encodable {
        let type = "app.bsky.embed.record"
        let record: Reference
        enum CodingKeys: String, CodingKey { case type = "$type", record }
    }
    struct RecordWithMediaEmbed: Encodable {
        let type = "app.bsky.embed.recordWithMedia"
        let record: QuoteEmbed
        let media: MediaEmbed
        enum CodingKeys: String, CodingKey { case type = "$type", record, media }
    }
    struct QuoteRecord: Encodable {
        let type = "app.bsky.feed.post"
        let text: String
        let facets: [PostRichTextEncoder.Facet]
        let createdAt: Date
        let embed: QuoteEmbed
        enum CodingKeys: String, CodingKey { case type = "$type", text, facets, createdAt, embed }
    }
    struct Blob: Codable {
        let type: String
        let reference: BlobReference
        let mimeType: String
        let size: Int
        enum CodingKeys: String, CodingKey { case type = "$type", reference = "ref", mimeType, size }
    }
    struct BlobReference: Codable {
        let link: String
        enum CodingKeys: String, CodingKey { case link = "$link" }
    }
    struct BlobUploadResponse: Decodable { let blob: Blob }
    struct AspectRatio: Encodable {
        let width: Int
        let height: Int
    }
    struct ImageEmbed: Encodable {
        let type = "app.bsky.embed.images"
        let images: [Image]
        enum CodingKeys: String, CodingKey { case type = "$type", images }
        struct Image: Encodable {
            let image: Blob
            let alt: String
            let aspectRatio: AspectRatio
        }
    }
    struct GalleryEmbed: Encodable {
        let type = "app.bsky.embed.gallery"
        let items: [Image]
        enum CodingKeys: String, CodingKey { case type = "$type", items }

        struct Image: Encodable {
            let type = "app.bsky.embed.gallery#image"
            let image: Blob
            let alt: String
            let aspectRatio: AspectRatio
            enum CodingKeys: String, CodingKey { case type = "$type", image, alt, aspectRatio }

            init(_ image: ImageEmbed.Image) {
                self.image = image.image
                alt = image.alt
                aspectRatio = image.aspectRatio
            }
        }
    }
    struct ExternalEmbed: Encodable {
        let type = "app.bsky.embed.external"
        let external: External
        enum CodingKeys: String, CodingKey { case type = "$type", external }

        struct External: Encodable {
            let uri: URL
            let title: String
            let description: String
            let thumbnail: Blob?
            enum CodingKeys: String, CodingKey { case uri, title, description, thumbnail = "thumb" }
        }
    }
    enum MediaEmbed: Encodable {
        case images(ImageEmbed)
        case gallery(GalleryEmbed)
        case external(ExternalEmbed)

        func encode(to encoder: Encoder) throws {
            switch self {
            case .images(let embed): try embed.encode(to: encoder)
            case .gallery(let embed): try embed.encode(to: encoder)
            case .external(let embed): try embed.encode(to: encoder)
            }
        }
    }
    enum PostEmbed: Encodable {
        case media(MediaEmbed)
        case quote(QuoteEmbed)
        case recordWithMedia(RecordWithMediaEmbed)

        func encode(to encoder: Encoder) throws {
            switch self {
            case .media(let embed): try embed.encode(to: encoder)
            case .quote(let embed): try embed.encode(to: encoder)
            case .recordWithMedia(let embed): try embed.encode(to: encoder)
            }
        }
    }
    struct PostRecord: Encodable {
        let type = "app.bsky.feed.post"
        let text: String
        let facets: [PostRichTextEncoder.Facet]
        let createdAt: Date
        let embed: PostEmbed?
        let reply: Reply?

        init(
            text: String,
            facets: [PostRichTextEncoder.Facet],
            createdAt: Date,
            embed: PostEmbed?,
            reply: Reply? = nil
        ) {
            self.text = text
            self.facets = facets
            self.createdAt = createdAt
            self.embed = embed
            self.reply = reply
        }

        enum CodingKeys: String, CodingKey { case type = "$type", text, facets, createdAt, embed, reply }
    }
    struct CreateRecord<Record: Encodable>: Encodable { let repo: String; let collection: String; let record: Record }
    struct DeleteRecord: Encodable { let repo: String; let collection: String; let rkey: String }
    struct CreateResponse: Decodable { let uri: String; let cid: String? }
}

private extension JSONEncoder {
    static var atProto: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
