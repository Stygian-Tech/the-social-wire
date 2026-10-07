package podcastcore

import (
	"encoding/base64"
	"testing"
)

func TestProtocolExactReferencesAndSuppliedArtwork(t *testing.T) {
	uri := "at://did:plc:creator/place.pod.show/show"
	show, err := ProtocolShow(uri, map[string]any{"title": "Show", "imageUrl": "https://example.com/show.png", "hosts": []any{map[string]any{"name": "Host", "imageUrl": "https://example.com/host.png"}}}, "")
	if err != nil {
		t.Fatal(err)
	}
	record := map[string]any{"showUri": uri, "title": "Episode", "publishedAt": "2026-10-05T00:00:00Z", "audioUrl": "https://example.com/a.mp3", "audioMimeType": "audio/mpeg", "chapters": []any{map[string]any{"startTime": 0.0, "title": "Intro", "img": "https://example.com/chapter.png"}}, "transcript": map[string]any{"url": "https://example.com/a.vtt", "type": "text/vtt"}}
	episode := ProtocolEpisode("at://did:plc:creator/place.pod.episode/episode", record, show, "")
	if episode == nil || len(episode.Transcripts) != 1 || episode.ShowArtworkURL == nil || *episode.ShowArtworkURL != *show.ArtworkURL || *episode.Chapters[0].ArtworkURL != "https://example.com/chapter.png" || len(show.Hosts) != 1 {
		t.Fatal("publisher metadata missing", episode)
	}
	record["showUri"] = uri + "other"
	if ProtocolEpisode("at://did:plc:creator/place.pod.episode/episode", record, show, "") != nil {
		t.Fatal("wrong show accepted")
	}
	record["showUri"] = uri
	delete(record, "publishedAt")
	if ProtocolEpisode("at://did:plc:creator/place.pod.episode/draft", record, show, "") != nil {
		t.Fatal("draft accepted")
	}
	if _, err := ProtocolShow("at://did:plc:creator/unsupported/show", map[string]any{"title": "Show"}, ""); err == nil {
		t.Fatal("unsupported schema accepted")
	}
}
func TestTranscriptSourceTimingAndRasterFormats(t *testing.T) {
	text, cues := ParseTranscript([]byte("WEBVTT\n\n00:01.250 --> 00:02.500\nHello <b>World</b>\n\n00:03.000 --> 00:04.000\nNext"), "text/vtt")
	if len(cues) != 2 || cues[0].StartSeconds != 1.25 || *cues[0].EndSeconds != 2.5 || text != "Hello World\nNext" {
		t.Fatal(text, cues)
	}
	_, cues = ParseTranscript([]byte("1\n00:00:12,200 --> 00:00:14,500\nTest"), "application/x-subrip")
	if len(cues) != 1 || cues[0].StartSeconds != 12.2 {
		t.Fatal(cues)
	}
	text, cues = ParseTranscript([]byte(`{"segments":[{"startTime":1.5,"endTime":3,"text":"Hello"}]}`), "application/json")
	if text != "Hello" || len(cues) != 1 || *cues[0].EndSeconds != 3 {
		t.Fatal(text, cues)
	}
	text, _ = ParseTranscript([]byte("<p>Hello &amp; Bye</p>"), "text/html")
	if text != "Hello & Bye" {
		t.Fatal(text)
	}
	png, _ := base64.StdEncoding.DecodeString("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5X8AAAAASUVORK5CYII=")
	if ImageMIME(png) != "image/png" {
		t.Fatal("PNG rejected")
	}
	for _, raw := range [][]byte{[]byte(`<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>`), []byte("<html>not an image</html>"), {137, 80, 78, 71, 13, 10, 26, 10}} {
		if ImageMIME(raw) != "" {
			t.Fatal("active or incomplete image accepted")
		}
	}
}
