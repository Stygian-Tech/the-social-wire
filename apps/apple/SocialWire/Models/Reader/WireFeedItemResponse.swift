import Foundation

struct WireFeedItemResponse: Decodable, Sendable {
    let item: WireFeedItem
    let html: String?
    let embedUrl: String?

    private enum CodingKeys: String, CodingKey {
        case item
        case html
        case embedUrl
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let item = try container.decodeIfPresent(WireFeedItem.self, forKey: .item) {
            self.item = item
            self.html = try container.decodeIfPresent(String.self, forKey: .html)
            self.embedUrl = try container.decodeIfPresent(String.self, forKey: .embedUrl)
        } else {
            self.item = try WireFeedItem(from: decoder)
            self.html = nil
            self.embedUrl = nil
        }
    }

    func toEntryDetail() -> EntryDetail {
        item.toEntryDetail(html: html, embedUrl: embedUrl)
    }
}
