import Foundation

struct SocialEmbed: Hashable, Sendable {
    var images: [SocialImage] = []
    var external: SocialExternalEmbed?
    var video: SocialVideo?
    var quote: SocialQuotedPost?
}

struct SocialQuotedPost: Hashable, Identifiable, Sendable {
    var id: String { uri }
    let uri: String
    let cid: String
    let author: SocialAuthor
    let text: String
    let createdAt: Date
}

struct SocialImage: Hashable, Identifiable, Sendable {
    var id: URL { fullsize }
    let thumbnail: URL
    let fullsize: URL
    let alt: String
    let width: Int?
    let height: Int?
}

struct SocialExternalEmbed: Hashable, Sendable {
    let uri: URL
    let title: String
    let description: String
    let thumbnail: URL?
}

struct SocialVideo: Hashable, Sendable {
    let playlist: URL
    let thumbnail: URL?
    let alt: String
}
