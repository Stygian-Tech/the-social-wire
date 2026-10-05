import Foundation
import Testing
import ThinAppViewCore

@testable import AppView

struct PodcastPublicationTests {
  @Test func captionChoiceDefaultsOnAndCanBeDisabled() throws {
    let decoder = JSONDecoder()
    let ordinary = try decoder.decode(
      PodcastClipRequest.self,
      from: Data("{\"episodeId\":\"e\",\"startSeconds\":1,\"endSeconds\":10}".utf8))
    #expect(ordinary.includeCaptions != false)
    let disabled = try decoder.decode(
      PodcastClipRequest.self,
      from: Data(
        "{\"episodeId\":\"e\",\"startSeconds\":1,\"endSeconds\":10,\"includeCaptions\":false}".utf8)
    )
    #expect(disabled.includeCaptions == false)
  }
  @Test func requiresExactRenderedPublicAssetsAndSourceMilliseconds() {
    var clip = PodcastClip(
      id: UUID().uuidString, episodeId: "episode:id", startSeconds: 1.234, endSeconds: 4.567,
      title: "Clip", status: "complete", createdAt: "2026-10-05T00:00:00Z")
    clip.audioUrl = "/v1/podcasts/assets?clipId=id&format=audio"
    clip.videoUrl = "/v1/podcasts/assets?clipId=id&format=video"
    clip.publicAudioUrl = "https://example.com/v1/podcasts/public/assets?clipId=id&format=audio"
    clip.publicVideoUrl = "https://example.com/v1/podcasts/public/assets?clipId=id&format=video"
    var record: [String: Any] = [
      "$type": "app.thesocialwire.podcast.clip", "episodeId": clip.episodeId, "title": clip.title,
      "startMillis": 1234, "endMillis": 4567, "audioUrl": clip.publicAudioUrl!,
      "videoUrl": clip.publicVideoUrl!,
    ]
    #expect(PodcastRoutes.matches(record, clip: clip))
    record["audioUrl"] = clip.audioUrl
    #expect(!PodcastRoutes.matches(record, clip: clip))
    record["audioUrl"] = clip.publicAudioUrl
    record["startMillis"] = 1235
    #expect(!PodcastRoutes.matches(record, clip: clip))
    record["startMillis"] = 1234
    record["episodeId"] = "another"
    #expect(!PodcastRoutes.matches(record, clip: clip))
  }
}
