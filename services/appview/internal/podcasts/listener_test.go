package podcasts

import (
	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
	"testing"
)

func TestSwiftEpisodeFingerprintJSONParity(t *testing.T) {
	episode := podcastcore.Episode{ID: "id", ShowID: "show", Title: "é/\u2028\u2029 literal \\u2028", PublishedAt: "date", AudioURL: "https://publisher.com/audio", DurationSeconds: ptr(1e-5)}
	// Expected bytes were verified with Foundation JSONEncoder [.sortedKeys].
	expected := `{"audioUrl":"https:\/\/publisher.com\/audio","chapters":[],"durationSeconds":1e-05,"id":"id","publishedAt":"date","showId":"show","title":"é\/` + "\u2028\u2029" + ` literal \\u2028","transcripts":[]}`
	actual, err := swiftJSON(episode)
	if err != nil || actual != expected {
		t.Fatalf("Swift encoding mismatch\nactual: %q\nexpected: %q\nerror: %v", actual, expected, err)
	}
	for _, test := range []struct {
		value    float64
		expected string
	}{{30, `{"v":30}`}, {1e-4, `{"v":0.0001}`}, {1e15, `{"v":1000000000000000}`}, {1e16, `{"v":1e+16}`}} {
		got, err := swiftJSON(map[string]float64{"v": test.value})
		if err != nil || got != test.expected {
			t.Fatal(got, test.expected, err)
		}
	}
}
