import Foundation
#if !canImport(Darwin)
import FoundationXML
#endif

enum OPMLParserError: LocalizedError, Equatable {
    case fileTooLarge
    case invalidDocument
    case noFeeds

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "Choose an OPML file smaller than 2 MB."
        case .invalidDocument:
            "This file is not valid OPML."
        case .noFeeds:
            "No RSS or Atom feeds were found in this file."
        }
    }
}

enum OPMLParser {
    static let maximumBytes = 2 * 1_024 * 1_024

    static func parse(_ data: Data) throws -> [OPMLFeed] {
        guard data.count <= maximumBytes else { throw OPMLParserError.fileTooLarge }

        let delegate = OutlineDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw OPMLParserError.invalidDocument }

        var seen = Set<String>()
        let feeds = delegate.feeds.filter { seen.insert($0.feedURL).inserted }
        guard !feeds.isEmpty else { throw OPMLParserError.noFeeds }
        return feeds
    }

    static func normalizeFeedURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = PublicURLNormalizer.normalizeHttpURLToHTTPS(trimmed)
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil
        else { return nil }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.url?.absoluteString
    }

    private final class OutlineDelegate: NSObject, XMLParserDelegate {
        var feeds: [OPMLFeed] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard elementName.caseInsensitiveCompare("outline") == .orderedSame,
                  let rawFeedURL = attributeDict["xmlUrl"] ?? attributeDict["xmlurl"],
                  let feedURL = OPMLParser.normalizeFeedURL(rawFeedURL)
            else { return }

            let rawTitle = attributeDict["title"] ?? attributeDict["text"]
            let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let siteURL = (attributeDict["htmlUrl"] ?? attributeDict["htmlurl"])
                .flatMap(OPMLParser.normalizeFeedURL)
            feeds.append(
                OPMLFeed(
                    title: title?.isEmpty == false ? title! : URL(string: feedURL)?.host ?? "RSS Feed",
                    feedURL: feedURL,
                    siteURL: siteURL
                )
            )
        }
    }
}
