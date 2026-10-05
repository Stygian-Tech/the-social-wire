import Hummingbird
import ThinAppViewCore

struct PodcastResolveResponse: Codable, Sendable, ResponseEncodable {
  let show: PodcastShow
  let episodes: [PodcastEpisode]
  var shows: [PodcastShow]? = nil
}
