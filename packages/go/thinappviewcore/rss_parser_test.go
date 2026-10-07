package thinappviewcore

import (
	"strings"
	"testing"
	"time"
)

func TestRSSCDATAAndRelativeImage(t *testing.T) {
	feed := "https://example.com/feed"
	data := []byte(`<rss><channel><title>Publication</title><item><title>Story</title><link>https://example.com/story</link><description><![CDATA[<p>Text</p><img src="/image.jpg">]]></description><pubDate>Mon, 05 Oct 2026 12:00:00 +0000</pubDate></item></channel></rss>`)
	parsed, err := ParseRSS(data, &feed, time.Unix(100, 0))
	if err != nil || len(parsed.Items) != 1 {
		t.Fatal(parsed, err)
	}
	item := parsed.Items[0]
	if *parsed.Title != "Publication" || item.PublishedAtISO != "2026-10-05T12:00:00Z" || item.ThumbnailURL == nil || *item.ThumbnailURL != "https://example.com/image.jpg" {
		t.Fatal(parsed)
	}
}

func TestFeedParsingPreservesFractionalDatesAndOrdersInstants(t *testing.T) {
	data := []byte(`<feed xmlns="http://www.w3.org/2005/Atom"><title>Example</title>
	<entry><id>older</id><title>Older</title><published>2024-01-02T04:00:00+02:00</published></entry>
	<entry><id>newer</id><title>Newer</title><published>2024-01-02T03:04:05.123Z</published></entry></feed>`)
	parsed, err := ParseRSS(data, nil, time.Unix(100, 0))
	if err != nil || len(parsed.Items) != 2 {
		t.Fatal(parsed, err)
	}
	if *parsed.Items[0].GUID != "newer" || parsed.Items[0].PublishedAtISO != "2024-01-02T03:04:05.123Z" {
		t.Fatal("timestamp replaced or sorted by formatted offset", parsed.Items)
	}
}

func TestFeedParsingSupportsJSONFeed(t *testing.T) {
	data := []byte(`{"version":"https://jsonfeed.org/version/1.1","title":"JSON publication","items":[{"id":"entry","url":"https://example.com/story","title":"Story","content_html":"<p>Body</p>","date_published":"2024-01-02T03:04:05.123Z"}]}`)
	parsed, err := ParseRSS(data, nil, time.Unix(100, 0))
	if err != nil || len(parsed.Items) != 1 {
		t.Fatal(parsed, err)
	}
	if *parsed.Items[0].ContentHTML != "<p>Body</p>" || *parsed.Items[0].GUID != "entry" {
		t.Fatal(parsed)
	}
}

func TestThumbnailIgnoresCommentsAndScriptsAndDecodesEntities(t *testing.T) {
	image := FirstImageURL(`<!-- <img src="https://example.com/comment.jpg"> --><script>"<img src='script.jpg'>"</script><IMG SRC = "https://example.com/real.jpg?a=1&amp;b=2">`)
	if image == nil || *image != "https://example.com/real.jpg?a=1&b=2" {
		t.Fatal(image)
	}
	image = FirstImageURL(`<meta content="https://example.com/og.jpg" property="og:image"><img src=article.jpg>`)
	if image == nil || *image != "article.jpg" {
		t.Fatal("image precedence changed", image)
	}
}

func TestRSSMixedTitleDoesNotLosePrefix(t *testing.T) {
	parsed, err := ParseRSS([]byte(`<rss><channel><item><title>A <b>bold</b> story</title></item></channel></rss>`), nil, time.Unix(100, 0))
	if err != nil || len(parsed.Items) != 1 {
		t.Fatal(parsed, err)
	}
	if !strings.Contains(parsed.Items[0].Title, "A ") || !strings.Contains(parsed.Items[0].Title, "bold") {
		t.Fatal("nested title text lost", parsed.Items[0].Title)
	}
}
func TestAtomEnclosureAndFallbackClock(t *testing.T) {
	data := []byte(`<feed xmlns="http://www.w3.org/2005/Atom"><title>Atom</title><entry><id>id</id><link rel="alternate" href="https://example.com/story"/><link rel="enclosure" type="image/jpeg" href="https://example.com/image.jpg"/></entry></feed>`)
	parsed, err := ParseRSS(data, nil, time.Unix(100, 0))
	if err != nil || len(parsed.Items) != 1 {
		t.Fatal(parsed, err)
	}
	item := parsed.Items[0]
	if item.Title != "Untitled" || item.PublishedAtISO != "1970-01-01T00:01:40Z" || item.ThumbnailURL == nil {
		t.Fatal(item)
	}
}
func TestRSSRejectsAudioThumbnail(t *testing.T) {
	kind := "audio/mpeg"
	if AcceptsMediaURL("https://example.com/audio.jpg", &kind, nil) {
		t.Fatal("audio accepted")
	}
}
