import Crypto
import Foundation

#if !canImport(Darwin)
  import FoundationXML
#endif

/// Audio enclosure parser independent of article ingestion and its retention limits.
public final class PodcastRSSParser: NSObject, XMLParserDelegate {
  private var stack: [String] = []
  private var texts: [String] = []
  private var showFields: [String: String] = [:]
  private var fields: [String: String] = [:]
  private var episodes: [[String: String]] = []
  private var transcripts: [PodcastTranscript] = []
  private var episodeTranscripts: [[PodcastTranscript]] = []
  private var hosts: [PodcastPerson] = []
  private var personAttributes: [String: String] = [:]
  private var chapters: [PodcastChapter] = []
  private var episodeChapters: [[PodcastChapter]] = []
  private var inItem = false
  private var sawRoot = false
  private var closedRoot = false
  private var invalidDocument = false
  private let feedURL: String
  public init(feedURL: String) { self.feedURL = feedURL }
  public static func identity(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  public func parse(_ data: Data) throws -> (show: PodcastShow, episodes: [PodcastEpisode]) {
    stack = []
    texts = []
    showFields = [:]
    fields = [:]
    episodes = []
    transcripts = []
    episodeTranscripts = []
    hosts = []
    personAttributes = [:]
    chapters = []
    episodeChapters = []
    inItem = false
    sawRoot = false
    closedRoot = false
    invalidDocument = false
    let parser = XMLParser(data: data)
    parser.delegate = self
    // FoundationXML on Linux can report success for a truncated document.
    // Require an observed root and its matching close, independently of parse().
    guard parser.parse(), parser.parserError == nil, !invalidDocument,
      sawRoot, closedRoot, stack.isEmpty, texts.isEmpty, !inItem
    else { throw PodcastParseError.invalidXML }
    let showID = "podcast:" + Self.identity(showFields["podcast:guid"] ?? feedURL)
    let show = PodcastShow(
      id: showID, title: showFields["title"] ?? "Untitled Podcast",
      description: showFields["description"], artworkUrl: showFields["artwork"], feedUrl: feedURL,
      sourceKind: "rss", sourceUri: nil, guid: showFields["podcast:guid"], episodeCollection: nil, hosts: hosts)
    let items = episodes.enumerated().compactMap { index, f -> PodcastEpisode? in
      guard let audio = f["audio"], Self.isAudio(url: audio, type: f["audioType"]),
        let url = URL(string: audio), ["https", "http"].contains(url.scheme?.lowercased() ?? "")
      else { return nil }
      let guid = f["guid"] ?? f["id"] ?? audio
      return PodcastEpisode(
        id: "episode:" + Self.identity(showID + "|" + guid), showId: showID,
        title: f["title"] ?? "Untitled Episode", description: f["description"] ?? f["summary"],
        publishedAt: Self.date(f["pubdate"] ?? f["published"]), audioUrl: audio,
        audioMimeType: f["audioType"], durationSeconds: Self.duration(f["itunes:duration"]),
        artworkUrl: f["artwork"] ?? show.artworkUrl, guid: guid, sourceUri: nil,
        transcripts: episodeTranscripts[index], chapters: episodeChapters[index],
        chapterSourceUrl: f["chapterSourceUrl"], showArtworkUrl: show.artworkUrl)
    }
    return (show, items)
  }
  public func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes a: [String: String]
  ) {
    let key = (qualifiedName ?? name).lowercased()
    if stack.isEmpty {
      if sawRoot { invalidDocument = true }
      sawRoot = true
    }
    stack.append(key)
    texts.append("")
    if key == "item" || key == "entry" {
      inItem = true
      fields = [:]
      transcripts = []
      chapters = []
    }
    if key == "enclosure" || (key == "link" && a["rel"] == "enclosure") {
      let url = a["url"] ?? a["href"]
      if let url, Self.isAudio(url: url, type: a["type"]), fields["audio"] == nil {
        fields["audio"] = url
        fields["audioType"] = a["type"]
      }
    }
    if key == "podcast:person", !inItem, stack.dropLast().last == "channel" {
      personAttributes = a
    }
    if key == "podcast:chapters", inItem, let url = PodcastChapterParser.safeURL(a["url"]) {
      fields["chapterSourceUrl"] = url
    }
    if key == "psc:chapter", inItem, chapters.count < 1000,
      let start = Self.duration(a["start"]), let title = a["title"] {
      chapters.append(PodcastChapter(startSeconds: start, title: String(title.prefix(512)),
        artworkUrl: PodcastChapterParser.safeURL(a["image"]), url: PodcastChapterParser.safeURL(a["href"])))
    }
    if key == "itunes:image", let href = a["href"] {
      if inItem { fields["artwork"] = href } else { showFields["artwork"] = href }
    }
    if key == "podcast:transcript", let url = a["url"] {
      transcripts.append(
        PodcastTranscript(url: url, type: a["type"] ?? "text/plain", language: a["language"]))
    }
  }
  public func parser(_ parser: XMLParser, foundCharacters text: String) {
    if !texts.isEmpty { texts[texts.count - 1] += text }
  }
  public func parser(_ parser: XMLParser, foundCDATA data: Data) {
    self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self))
  }
  public func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) {
    guard let key = stack.popLast(), let text = texts.popLast(),
      key == (qualifiedName ?? name).lowercased()
    else {
      invalidDocument = true
      return
    }
    if stack.isEmpty { closedRoot = true }
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !texts.isEmpty { texts[texts.count - 1] += text }
    if key == "item" || key == "entry" {
      episodes.append(fields)
      episodeTranscripts.append(transcripts)
      episodeChapters.append(chapters.sorted { $0.startSeconds < $1.startSeconds })
      inItem = false
      return
    }
    if key == "podcast:person", !inItem, stack.last == "channel", hosts.count < 100 {
      hosts += PodcastChapterParser.people([["name": clean, "role": personAttributes["role"] ?? "host",
        "img": personAttributes["img"] ?? "", "href": personAttributes["href"] ?? ""]])
      personAttributes = [:]
    }
    if inItem {
      if !clean.isEmpty { fields[key] = clean }
    } else if !clean.isEmpty && ["title", "description", "podcast:guid"].contains(key)
      && stack.last == "channel"
    {
      showFields[key] = clean
    } else if key == "url" && stack.last == "image" {
      showFields["artwork"] = clean
    }
  }
  public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
    invalidDocument = true
  }
  public static func isAudio(url: String, type: String?) -> Bool {
    if let type { return type.lowercased().hasPrefix("audio/") }
    return ["mp3", "m4a", "aac", "ogg", "opus", "wav", "flac"].contains(
      URL(string: url)?.pathExtension.lowercased() ?? "")
  }
  public static func duration(_ raw: String?) -> Double? {
    guard let raw else { return nil }
    let pieces = raw.split(separator: ":")
    var result = 0.0
    for p in pieces {
      guard let n = Double(p), n >= 0, n.isFinite else { return nil }
      result = result * 60 + n
    }
    return result
  }
  private static func date(_ raw: String?) -> String {
    let iso = ISO8601DateFormatter()
    if let raw, iso.date(from: raw) != nil { return raw }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z"] {
      f.dateFormat = format
      if let raw, let date = f.date(from: raw) { return iso.string(from: date) }
    }
    return "1970-01-01T00:00:00Z"
  }
}
