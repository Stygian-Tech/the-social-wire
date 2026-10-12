package publicationcore

import "testing"

func TestPodcastFeedBody(t *testing.T) {
	for _, test := range []struct {
		name string
		body string
		want bool
	}{
		{"rss audio mime", `<rss><channel><item><enclosure url="https://example.com/media" type="audio/mpeg"/></item></channel></rss>`, true},
		{"rss audio extension", `<rss><channel><item><enclosure url="https://example.com/episode.mp3"/></item></channel></rss>`, true},
		{"truncated podcast", `<rss><channel><item><enclosure url="https://example.com/episode.mp3"/>`, true},
		{"atom audio", `<feed xmlns="http://www.w3.org/2005/Atom"><entry><link rel="enclosure" type="audio/ogg" href="https://example.com/audio"/></entry></feed>`, true},
		{"empty podcast", `<rss xmlns:apple="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><apple:author>Host</apple:author></channel></rss>`, true},
		{"podcast index", `<rss xmlns:p="https://podcastindex.org/namespace/1.0"><channel><p:guid>show</p:guid></channel></rss>`, true},
		{"news", `<rss><channel><item><title>Podcast News</title><description>audio/mpeg</description></item></channel></rss>`, false},
		{"image enclosure", `<rss><channel><item><enclosure url="https://example.com/photo.jpg" type="image/jpeg"/></item></channel></rss>`, false},
		{"article audio link", `<feed xmlns="http://www.w3.org/2005/Atom"><entry><link rel="alternate" href="https://example.com/story.mp3"/></entry></feed>`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := podcastFeedBody([]byte(test.body)); got != test.want {
				t.Fatalf("podcast=%v, want %v", got, test.want)
			}
		})
	}
}
