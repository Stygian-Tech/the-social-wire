import Foundation

@MainActor
final class RSSService {
    func publicationID(normalizedFeedURL: String) -> String {
        "rss:\(normalizedFeedURL)"
    }

    func normalizedFeedURL(from publicationID: String) -> String? {
        publicationID.hasPrefix("rss:") ? String(publicationID.dropFirst(4)) : nil
    }

    func normalizeFeedURL(_ raw: String) -> String {
        PublicURLNormalizer.normalizeHttpURLToHTTPS(raw)
    }

    func discoveredPublication(from record: RepoRecord<SkyreaderFeedSubscriptionRecord>) -> DiscoveredPublication? {
        guard let rawFeed = record.value.feedUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !rawFeed.isEmpty else {
            return nil
        }
        let normalized = normalizeFeedURL(rawFeed)
        let title = record.value.customTitle ?? record.value.title ?? URL(string: normalized)?.host ?? "RSS Feed"
        let icon = record.value.customIconUrl ?? record.value.siteUrl.flatMap { URL(string: $0)?.host.map { "https://\($0)/favicon.ico" } }
        return DiscoveredPublication(
            publicationId: publicationID(normalizedFeedURL: normalized),
            subscriptionPublicationId: record.uri,
            authorDid: "did:web:skyreader.rss",
            authorHandle: "RSS",
            title: title,
            iconUrl: icon,
            discoveredAt: record.value.updatedAt ?? record.value.createdAt
        )
    }

    func entries(feedURL: String) async throws -> [EntryListItem] {
        let feed = try await parseFeed(url: URL(string: normalizeFeedURL(feedURL))!)
        return feed.items.map { item in
            EntryListItem(
                entryId: "rss:\(feedURL)#\(item.id)",
                title: item.title,
                summary: item.summary,
                publishedAt: item.publishedAt,
                thumbnailUrl: item.imageURL,
                thumbnailFallbackUrl: nil
            )
        }
    }

    func detail(entryID: String, feedURL: String) async throws -> EntryDetail? {
        let feed = try await parseFeed(url: URL(string: normalizeFeedURL(feedURL))!)
        guard let item = feed.items.first(where: { "rss:\(feedURL)#\($0.id)" == entryID }) else { return nil }
        return EntryDetail(
            entryId: entryID,
            title: item.title,
            publishedAt: item.publishedAt,
            contentHtml: item.contentHTML ?? item.summary ?? "",
            originalUrl: item.link,
            embedUrl: item.link
        )
    }

    private func parseFeed(url: URL) async throws -> RSSFeed {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SocialWireError.badResponse("Could not load feed.")
        }
        let parser = RSSParser(data: data)
        return parser.parse()
    }
}

struct RSSFeed: Sendable {
    var title: String?
    var items: [RSSItem]
}

struct RSSItem: Sendable {
    var id: String
    var title: String
    var link: String?
    var summary: String?
    var contentHTML: String?
    var publishedAt: String
    var imageURL: String?
}

final class RSSParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var currentElement = ""
    private var currentText = ""
    private var inItem = false
    private var feedTitle: String?
    private var item = PartialRSSItem()
    private var items: [RSSItem] = []

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() -> RSSFeed {
        parser.parse()
        return RSSFeed(title: feedTitle, items: items.sorted { $0.publishedAt > $1.publishedAt })
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = qName ?? elementName
        currentText = ""
        let lower = currentElement.lowercased()
        if lower == "item" || lower == "entry" {
            inItem = true
            item = PartialRSSItem()
        }
        if inItem, ["media:thumbnail", "media:content", "enclosure"].contains(lower), item.imageURL == nil {
            item.imageURL = attributeDict["url"]
        }
        if inItem, lower == "link", let href = attributeDict["href"], item.link == nil {
            item.link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        currentText += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = (qName ?? elementName).lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if inItem {
            switch name {
            case "title": item.title = text
            case "link": if item.link == nil { item.link = text }
            case "guid", "id": item.id = text
            case "description", "summary": item.summary = text
            case "content:encoded", "content": item.contentHTML = text
            case "pubdate", "published", "updated": item.publishedAt = Self.normalizedDate(text)
            default: break
            }
        } else if name == "title", feedTitle == nil {
            feedTitle = text
        }

        if name == "item" || name == "entry" {
            items.append(item.finalized())
            inItem = false
        }
        currentText = ""
    }

    private static func normalizedDate(_ raw: String) -> String {
        if DateFormatters.date(from: raw) != nil { return raw }
        if let date = DateFormatter.rfc822.date(from: raw) {
            return DateFormatters.string(from: date)
        }
        return DateFormatters.string()
    }

    private struct PartialRSSItem {
        var id: String?
        var title: String?
        var link: String?
        var summary: String?
        var contentHTML: String?
        var publishedAt: String?
        var imageURL: String?

        func finalized() -> RSSItem {
            RSSItem(
                id: id ?? link ?? UUID().uuidString,
                title: title?.isEmpty == false ? title! : "Untitled",
                link: link,
                summary: summary,
                contentHTML: contentHTML,
                publishedAt: publishedAt ?? DateFormatters.string(),
                imageURL: imageURL
            )
        }
    }
}

private extension DateFormatter {
    nonisolated(unsafe) static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}
