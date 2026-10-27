import Foundation

// App View image URLs may flatten animation. Keep the original GIF blob reference
// from the post record so a visible image can fetch it from the author's PDS.
struct OriginalGIFEmbed: Decodable {
    private let imageCIDs: [String?]

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case images, items, media
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let type = try? container.decode(String.self, forKey: .type) else {
            imageCIDs = []
            return
        }
        switch type {
        case "app.bsky.embed.recordWithMedia":
            imageCIDs = (try? container.decode(Self.self, forKey: .media))?.imageCIDs ?? []
        case "app.bsky.embed.images":
            imageCIDs = (try? container.decode([Image].self, forKey: .images))?.map(\.gifCID) ?? []
        case "app.bsky.embed.gallery":
            imageCIDs = (try? container.decode([Image].self, forKey: .items))?.map(\.gifCID) ?? []
        default:
            imageCIDs = []
        }
    }

    func recoveringGIFs(in images: [TimelineImage], authorDID: String) -> [TimelineImage] {
        // Avoid associating a blob with a different image when an unsupported
        // record shape and the rendered embed have different item counts.
        guard imageCIDs.count == images.count else { return images }
        return zip(images, imageCIDs).map { image, cid in
            guard let cid else { return image }
            return TimelineImage(
                thumbnailURL: image.thumbnailURL,
                fullsizeURL: image.fullsizeURL,
                altText: image.altText,
                width: image.width,
                height: image.height,
                originalGIFDID: authorDID,
                originalGIFCID: cid
            )
        }
    }

    private struct Image: Decodable {
        let gifCID: String?

        private enum CodingKeys: String, CodingKey { case image }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            let blob = try? container?.decode(Blob.self, forKey: .image)
            gifCID = blob?.mimeType.lowercased() == "image/gif" && blob?.reference.link.isEmpty == false
                ? blob?.reference.link : nil
        }
    }

    private struct Blob: Decodable {
        let mimeType: String
        let reference: Reference
        private enum CodingKeys: String, CodingKey {
            case mimeType
            case reference = "ref"
        }
    }

    private struct Reference: Decodable {
        let link: String
        private enum CodingKeys: String, CodingKey { case link = "$link" }
    }
}
