import Foundation

/// Explicit adapters for supported public schemas; never uses title matching.
public enum PodcastProtocolAdapter {
  public static let collections = [
    "org.atpodcasting.podcast": "org.atpodcasting.episode", "place.pod.show": "place.pod.episode",
    "live.voxport.podcast.series": "live.voxport.podcast.episode",
  ]
  public static func show(uri: String, record: [String: Any], blobBase: String? = nil) throws
    -> PodcastShow
  {
    guard let parsed = RenderFieldExtractor.parseAtUri(uri), collections[parsed.collection] != nil,
      let title = record["title"] as? String
    else { throw PodcastParseError.unsupportedSource }
    return PodcastShow(
      id: uri, title: title, description: (record["description"] ?? record["summary"]) as? String,
      artworkUrl: ((record["imageUrl"] ?? record["artworkUrl"] ?? record["coverImageUrl"])
        as? String)
        ?? ["artwork", "cover", "image"].compactMap {
          RenderFieldExtractor.extractBlobLink(record[$0]).flatMap {
            RenderFieldExtractor.buildSyncGetBlobUrl(
              pdsBase: blobBase, repoDid: parsed.did, cid: $0)
          }
        }.first, feedUrl: (record["feedUrl"] ?? record["rssFeedUrl"]) as? String,
      sourceKind: "atproto", sourceUri: uri,
      guid: (record["podcastGuid"] ?? record["guid"]) as? String,
      episodeCollection: collections[parsed.collection])
  }
  public static func episode(
    uri: String, record: [String: Any], show: PodcastShow, blobBase: String? = nil
  ) -> PodcastEpisode? {
    guard let parsed = RenderFieldExtractor.parseAtUri(uri), let showURI = show.sourceUri,
      let showParsed = RenderFieldExtractor.parseAtUri(showURI),
      collections[showParsed.collection] == parsed.collection
    else { return nil }
    let reference =
      (record["showUri"] as? String) ?? ((record["series"] as? [String: Any])?["uri"] as? String)
    let podcast = record["podcast"] as? [String: Any]
    if parsed.collection == "org.atpodcasting.episode" {
      guard let guid = show.guid, podcast?["podcastGuid"] as? String == guid else { return nil }
    } else {
      guard reference == showURI else { return nil }
    }
    let media = record["media"] as? [String: Any]
    let blob = record["audio"] as? [String: Any]
    let audio =
      (media?["url"] ?? record["audioUrl"]) as? String
      ?? RenderFieldExtractor.extractBlobLink(blob).flatMap {
        RenderFieldExtractor.buildSyncGetBlobUrl(pdsBase: blobBase, repoDid: parsed.did, cid: $0)
      }
    let mime =
      (media?["mimeType"] ?? record["audioMimeType"] ?? record["audioType"] ?? blob?["mimeType"])
      as? String
    guard let audio, PodcastRSSParser.isAudio(url: audio, type: mime),
      let title = record["title"] as? String
    else { return nil }
    guard record["publishedAt"] as? String != nil else { return nil }
    var references = (record["transcripts"] ?? record["transcript"]) as? [[String: Any]] ?? []
    if references.isEmpty, let singular = record["transcript"] as? [String: Any] {
      references = [singular]
    }
    var transcripts = references.compactMap { item -> PodcastTranscript? in
      guard let url = item["url"] as? String else { return nil }
      return PodcastTranscript(
        url: url, type: (item["type"] ?? item["mimeType"]) as? String ?? "text/plain",
        language: item["language"] as? String)
    }
    if let url = record["transcriptUrl"] as? String {
      transcripts.append(
        PodcastTranscript(url: url, type: record["transcriptMimeType"] as? String ?? "text/plain"))
    }
    return PodcastEpisode(
      id: uri, showId: show.id, title: title,
      description: (record["description"] ?? record["summary"]) as? String,
      publishedAt: (record["publishedAt"] ?? record["createdAt"]) as? String
        ?? "1970-01-01T00:00:00Z", audioUrl: audio, audioMimeType: mime,
      durationSeconds: (record["durationSeconds"] ?? record["duration"]) as? Double,
      artworkUrl: (record["imageUrl"] as? String) ?? show.artworkUrl,
      guid: (record["feedItemGuid"] ?? record["guid"] ?? record["importedGuid"]) as? String,
      sourceUri: uri, transcripts: transcripts)
  }
}
