import Foundation

public enum PodcastPrivateCatalog {
  public static func isPrivateID(_ id: String) -> Bool { id.hasPrefix("private-podcast:") }

  /// Credentials in URL userinfo are unsupported; query/path tokens stay on the server.
  public static func isAllowedURL(_ raw: String) -> Bool {
    guard let components = URLComponents(string: raw),
      components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil, components.url != nil
    else { return false }
    return true
  }

  public static func scope(
    viewer: String, feedURL: String, show: PodcastShow, episodes: [PodcastEpisode]
  ) -> (show: PodcastShow, episodes: [PodcastEpisode]) {
    var show = show
    show.id = "private-podcast:show:" + PodcastRSSParser.identity(viewer + "|" + feedURL)
    show.sourceKind = "private-rss"
    show.visibility = "private"
    show.sourceUri = nil
    show.bridgeJobId = nil
    show.bridgeStatus = nil
    let episodes = episodes.map { original in
      var episode = original
      episode.id = "private-podcast:episode:" + PodcastRSSParser.identity(show.id + "|" + (original.guid ?? original.id))
      episode.showId = show.id
      episode.sourceUri = nil
      episode.visibility = "private"
      return episode
    }
    return (show, episodes)
  }

  /// Publisher HTML and prose can also contain signed source links; clients receive labels only.
  public static func visibleText(_ text: String) -> String {
    text.replacingOccurrences(of: #"https?://[^\s<>\"']+"#, with: "[Private Link]",
      options: [.regularExpression, .caseInsensitive])
  }

  public static func visible(_ original: PodcastShow) -> PodcastShow {
    var show = original
    show.title = visibleText(show.title)
    show.description = show.description.map(visibleText)
    show.feedUrl = nil
    show.sourceUri = nil
    show.guid = nil
    show.artworkUrl = nil
    show.episodeCollection = nil
    show.bridgeJobId = nil
    show.bridgeStatus = nil
    return show
  }

  public static func visible(_ original: PodcastEpisode) -> PodcastEpisode {
    var episode = original
    episode.title = visibleText(episode.title)
    episode.description = episode.description.map(visibleText)
    episode.audioUrl = "/v1/podcasts/media?episodeId=" + episode.id
    episode.artworkUrl = nil
    episode.sourceUri = nil
    episode.guid = nil
    episode.transcripts = episode.transcripts.map {
      var transcript = $0
      transcript.url = ""
      return transcript
    }
    return episode
  }
}
