import Foundation

struct ATProtoBlob: Codable, Equatable, Sendable {
    let type: String
    let reference: ATProtoBlobReference
    let mimeType: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case reference = "ref"
        case mimeType
        case size
    }
}

struct ATProtoBlobReference: Codable, Equatable, Sendable {
    let link: String

    enum CodingKeys: String, CodingKey {
        case link = "$link"
    }
}
