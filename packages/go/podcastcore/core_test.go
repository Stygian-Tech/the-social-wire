package podcastcore

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"testing"
)

func TestCatalogCodableContract(t *testing.T) {
	var show Show
	if err := json.Unmarshal([]byte(`{"id":"show","title":"Show","sourceKind":"rss"}`), &show); err != nil || show.Hosts == nil {
		t.Fatalf("legacy show: %#v %v", show, err)
	}
	var episode Episode
	valid := `{"id":"episode","showId":"show","title":"Episode","publishedAt":"2026-10-05T00:00:00Z","audioUrl":"https://example.com/a.mp3","transcripts":[]}`
	if err := json.Unmarshal([]byte(valid), &episode); err != nil || episode.Chapters == nil {
		t.Fatalf("legacy episode: %#v %v", episode, err)
	}
	for _, invalid := range []string{strings.Replace(valid, `,"transcripts":[]`, "", 1), strings.Replace(valid, `"transcripts":[]`, `"transcripts":null`, 1), strings.Replace(valid, `"id":"episode"`, `"id":null`, 1)} {
		if json.Unmarshal([]byte(invalid), &episode) == nil {
			t.Fatalf("accepted missing required field %s", invalid)
		}
	}
	show.ArtworkURL = pointer("https://example.com/art.png")
	show.SourceURI = pointer("at://did:plc:creator/place.pod.show/one")
	data, err := json.Marshal(show)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(data, []byte(`"artworkUrl"`)) || !bytes.Contains(data, []byte(`"sourceUri"`)) || !bytes.Contains(data, []byte(`"hosts":[]`)) || bytes.Contains(data, []byte(`"artworkURL"`)) {
		t.Fatalf("wire field mismatch %s", data)
	}
	var state ListenerState
	if json.Unmarshal([]byte(`{}`), &state) == nil {
		t.Fatal("synthesized Swift state requires fields")
	}
}
func TestListenerValidationAndRewind(t *testing.T) {
	s := DefaultListenerState()
	s.Progress["episode"] = Progress{PositionSeconds: 5, UpdatedAt: "2026-10-05T00:00:00.123Z"}
	for _, row := range []struct{ speed, want float64 }{{.5, .75}, {3, 2}, {1.3, 1.25}, {math.NaN(), 1}} {
		s.PlaybackSpeed = row.speed
		if s.Validate() {
			t.Fatal("invalid speed accepted")
		}
		s.NormalizePlaybackSpeed()
		if s.PlaybackSpeed != row.want || !s.Validate() || s.Progress["episode"].PositionSeconds != 5 {
			t.Fatal(s)
		}
	}
	s.Progress["episode"] = Progress{PositionSeconds: -1, UpdatedAt: "2026-10-05T00:00:00Z"}
	if s.Validate() {
		t.Fatal("negative progress accepted")
	}
}
func TestPrivateEncryptionBindingAndRedaction(t *testing.T) {
	storage, err := NewPrivateStorage(base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32)))
	if err != nil {
		t.Fatal(err)
	}
	secret := "https://example.com/rss?token=private-secret"
	sealed, err := storage.Seal(secret, "did:plc:é", "feed", "one")
	if err != nil {
		t.Fatal(err)
	}
	if got, err := storage.Open(sealed, "did:plc:é", "feed", "one"); err != nil || got != secret {
		t.Fatalf("round trip %q %v", got, err)
	}
	for _, ctx := range [][3]string{{"did:plc:other", "feed", "one"}, {"did:plc:é", "episode", "one"}, {"did:plc:é", "feed", "two"}} {
		if _, err := storage.Open(sealed, ctx[0], ctx[1], ctx[2]); !errors.Is(err, ErrPrivateStorageUnavailable) {
			t.Fatal("accepted wrong binding")
		}
	}
	raw, _ := base64.StdEncoding.DecodeString(strings.TrimPrefix(sealed, "v1."))
	raw[len(raw)-1] ^= 1
	if _, err := storage.Open("v1."+base64.StdEncoding.EncodeToString(raw), "did:plc:é", "feed", "one"); err == nil {
		t.Fatal("accepted corrupt tag")
	}
	if _, err := NewPrivateStorage("invalid"); err == nil {
		t.Fatal("accepted invalid key")
	}
	show := Show{ID: "show", Title: secret, Description: &secret, ArtworkURL: &secret, FeedURL: &secret, SourceKind: "rss", Hosts: []Person{{Name: secret, ImageURL: &secret, URL: &secret}}}
	episode := Episode{ID: "episode", Title: secret, AudioURL: secret, Guid: pointer("guid"), ArtworkURL: &secret, ShowArtworkURL: &secret, ChapterSourceURL: &secret, Chapters: []Chapter{{Title: secret, ArtworkURL: &secret, URL: &secret}}, Transcripts: []Transcript{{URL: secret, Type: "text/vtt"}}}
	scoped, episodes := ScopePrivate("viewer", secret, show, []Episode{episode})
	other, _ := ScopePrivate("other", secret, show, nil)
	if scoped.ID == other.ID || episodes[0].ShowID != scoped.ID {
		t.Fatal("private scope collision")
	}
	safeShow, safeEpisode := VisibleShow(scoped), VisibleEpisode(episodes[0])
	data, _ := json.Marshal([]any{safeShow, safeEpisode})
	if bytes.Contains(data, []byte("private-secret")) || safeEpisode.Chapters[0].URL != nil || safeEpisode.ChapterSourceURL != nil || safeEpisode.Transcripts[0].URL != "" {
		t.Fatalf("leak %s", data)
	}
	if show.Hosts[0].URL == nil || episode.Chapters[0].URL == nil {
		t.Fatal("redaction mutated source catalog")
	}
}
func TestRSSURLAndSearchPrivacy(t *testing.T) {
	for _, u := range []string{"https://example.com/rss", " https://example.com/rss?FORMAT=RSS2 "} {
		if !PublicRSSURLAllowed(u) {
			t.Fatal(u)
		}
	}
	for _, u := range []string{"http://example.com/rss", "https://user:pass@example.com/rss", "https://example.com/rss?token=secret", "https://example.com/rss?feed=private", "https://example.com/rss?format=rss&format=private"} {
		if PublicRSSURLAllowed(u) {
			t.Fatal(u)
		}
	}
	if !PrivateURLAllowed("https://example.com/rss?token=secret") {
		t.Fatal("private signed URL denied")
	}
	if !SearchMatches("resume HOST", "Résumé", nil, []Person{{Name: "Host"}}) || SearchMatches("credential", "Show", nil, nil) {
		t.Fatal("publisher prose search")
	}
	req := SearchRequest{Query: " foo/bar <&> "}
	binding := SearchBinding("did:plc:a", req)
	if binding != Identity(`["did:plc:a","foo\/bar <&>","all",""]`) {
		t.Fatal("Swift binding mismatch", binding)
	}
	cursor, _ := (SearchCursor{Binding: binding, Entity: 1, ID: "episode"}).Encode()
	if _, err := DecodeSearchCursor(&cursor, SearchBinding("other", req)); err == nil {
		t.Fatal("cross viewer cursor accepted")
	}
	if _, err := DecodeSearchCursor(&cursor, binding); err != nil {
		t.Fatal(err)
	}
	if (SearchRequest{Query: strings.Repeat("👨‍👩‍👧‍👦", 200)}).Validate() != nil {
		t.Fatal("grapheme boundary")
	}
}
func TestRSSCompleteCatalogAndMetadata(t *testing.T) {
	var items strings.Builder
	for i := 0; i < 205; i++ {
		fmt.Fprintf(&items, `<item><guid>episode-%d</guid><title>Episode %d</title><enclosure url="https://example.com/%d.mp3" type="audio/mpeg"/><itunes:duration>1:02:03</itunes:duration><podcast:transcript url="https://example.com/a.vtt" type="text/vtt"/><psc:chapter start="01:02.500" title="Next" image="https://example.com/chapter.png"/></item>`, i, i, i)
	}
	xml := `<rss xmlns:itunes="urn:itunes" xmlns:podcast="urn:podcast" xmlns:psc="urn:psc"><channel><title>Show</title><podcast:guid>guid</podcast:guid><podcast:person img="https://example.com/host.png">Host</podcast:person><podcast:person role="guest">Guest</podcast:person>` + items.String() + `</channel></rss>`
	show, episodes, err := ParseRSS([]byte(xml), "https://example.com/rss")
	if err != nil {
		t.Fatal(err)
	}
	other, repeated, err := ParseRSS([]byte(xml), "https://other.example/rss")
	if err != nil {
		t.Fatal(err)
	}
	if len(episodes) != 205 || show.ID != other.ID || episodes[0].ID != repeated[0].ID || *episodes[0].DurationSeconds != 3723 || len(show.Hosts) != 1 || episodes[0].Chapters[0].StartSeconds != 62.5 || episodes[0].Transcripts[0].Type != "text/vtt" {
		t.Fatal("catalog metadata lost")
	}
	for _, bad := range []string{"", "<rss><channel>", "<rss><channel></rss>", "<rss/><rss/>", "<rss><channel/></rss>extra"} {
		if _, _, err := ParseRSS([]byte(bad), "https://example.com/rss"); !errors.Is(err, ErrInvalidXML) {
			t.Fatal("accepted incomplete XML", bad, err)
		}
	}
	chapters := ParseChapters([]byte(`{"chapters":[{"startTime":3,"img":"https://example.com/art.png"},{"startTime":0},{"startTime":1,"toc":false},{"startTime":-1},{"startTime":10},{"startTime":"bad"}]}`), pointer(10.0))
	if len(chapters) != 2 || chapters[0].StartSeconds != 0 || *chapters[1].ArtworkURL != "https://example.com/art.png" {
		t.Fatal(chapters)
	}
}
