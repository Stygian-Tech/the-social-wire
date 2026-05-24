import Foundation
#if !canImport(Darwin)
import FoundationXML
#endif

public struct ParsedRssItem: Sendable {
  public var guid: String?
  public var title: String
  public var link: String?
  public var summary: String?
  public var contentHTML: String?
  public var publishedAtISO: String
  public var thumbnailUrl: String?

  public init(
    guid: String? = nil,
    title: String,
    link: String? = nil,
    summary: String? = nil,
    contentHTML: String? = nil,
    publishedAtISO: String,
    thumbnailUrl: String? = nil
  ) {
    self.guid = guid
    self.title = title
    self.link = link
    self.summary = summary
    self.contentHTML = contentHTML
    self.publishedAtISO = publishedAtISO
    self.thumbnailUrl = thumbnailUrl
  }
}

public struct ParsedRssFeed: Sendable {
  public var title: String?
  public var items: [ParsedRssItem]
}

public final class RssFeedParser: NSObject, XMLParserDelegate, @unchecked Sendable {
  private let parser: XMLParser
  private let feedURL: String?
  private var currentElement = ""
  private var currentText = ""
  private var inItem = false
  private var feedTitle: String?
  private var item = PartialRssItem()
  private var items: [ParsedRssItem] = []

  public init(data: Data, feedURL: String? = nil) {
    self.feedURL = feedURL
    parser = XMLParser(data: data)
    super.init()
    parser.delegate = self
  }

  public func parse() -> ParsedRssFeed {
    _ = parser.parse()
    let sorted = items.sorted { $0.publishedAtISO > $1.publishedAtISO }
    return ParsedRssFeed(title: feedTitle, items: sorted)
  }

  public func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    currentElement = qName ?? elementName
    currentText = ""
    let key = elementKey(qName, elementName: elementName)
    if key == "item" || key == "entry" {
      inItem = true
      item = PartialRssItem()
    }

    guard inItem else { return }

    if isMediaThumbnail(key), item.imageURL == nil, let url = attributeDict["url"] {
      item.imageURL = url
      return
    }

    if isMediaContent(key) || isEnclosure(key), item.imageURL == nil {
      let url = attributeDict["url"]
      if RssFeedThumbnailExtractor.acceptsMediaURL(
        url: url,
        type: attributeDict["type"],
        medium: attributeDict["medium"]
      ) {
        item.imageURL = url
      }
      return
    }

    if isItunesImage(key), item.imageURL == nil {
      if let href = attributeDict["href"] {
        item.imageURL = href
      }
      return
    }

    if key == "link" {
      let rel = attributeDict["rel"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let href = attributeDict["href"]
      if let href,
         ["enclosure", "preview"].contains(rel ?? ""),
         item.imageURL == nil,
         RssFeedThumbnailExtractor.acceptsMediaURL(
           url: href,
           type: attributeDict["type"],
           medium: attributeDict["medium"]
         )
      {
        item.imageURL = href
        return
      }
      if item.link == nil, let href, rel == nil || rel == "alternate" || rel?.isEmpty == true {
        item.link = href
      }
    }
  }

  public func parser(_ parser: XMLParser, foundCharacters string: String) {
    currentText += string
  }

  public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    currentText += String(data: CDATABlock, encoding: .utf8) ?? ""
  }

  public func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let key = elementKey(qName, elementName: elementName)
    let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

    if inItem {
      switch key {
      case "title": item.title = text
      case "link":
        if item.link == nil, !text.isEmpty { item.link = text }
      case "guid", "id": item.guid = text
      case "description", "summary": item.summary = text
      case "content:encoded", "content": item.contentHTML = text
      case "pubdate", "published", "updated": item.publishedAtISO = Self.normalizedDateISO(text)
      default:
        if isItunesImage(key), item.imageURL == nil, !text.isEmpty {
          item.imageURL = text
        }
      }
    } else if key == "title", feedTitle == nil {
      feedTitle = text
    }

    if key == "item" || key == "entry" {
      items.append(item.finalized(feedURL: feedURL))
      inItem = false
    }
    currentText = ""
  }

  private static func normalizedDateISO(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, ISO8601DateFormatter().date(from: trimmed) != nil {
      return trimmed
    }
    let rfc822 = DateFormatter()
    rfc822.locale = Locale(identifier: "en_US_POSIX")
    rfc822.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    if let date = rfc822.date(from: trimmed) {
      return ISO8601DateFormatter().string(from: date)
    }
    return ISO8601DateFormatter().string(from: Date())
  }

  private func elementKey(_ qName: String?, elementName: String) -> String {
    (qName ?? elementName).lowercased()
  }

  private func isMediaThumbnail(_ key: String) -> Bool {
    key == "media:thumbnail" || key.hasSuffix(":thumbnail")
  }

  private func isMediaContent(_ key: String) -> Bool {
    key == "media:content" || key.hasSuffix(":content")
  }

  private func isEnclosure(_ key: String) -> Bool {
    key == "enclosure"
  }

  private func isItunesImage(_ key: String) -> Bool {
    key == "itunes:image" || key.hasSuffix(":image")
  }

  private struct PartialRssItem {
    var guid: String?
    var title: String?
    var link: String?
    var summary: String?
    var contentHTML: String?
    var publishedAtISO: String?
    var imageURL: String?

    func finalized(feedURL: String?) -> ParsedRssItem {
      let thumbnailUrl = RssFeedThumbnailExtractor.resolveThumbnail(
        storedURL: imageURL,
        contentHTML: contentHTML,
        summary: summary,
        articleLink: link,
        feedURL: feedURL
      )
      return ParsedRssItem(
        guid: guid,
        title: title?.isEmpty == false ? title! : "Untitled",
        link: link,
        summary: summary,
        contentHTML: contentHTML,
        publishedAtISO: publishedAtISO ?? ISO8601DateFormatter().string(from: Date()),
        thumbnailUrl: thumbnailUrl
      )
    }
  }
}
