package thinappviewcore

import (
	"context"
	"net/http"
	"testing"
	"time"
)

type fixtureGetter func(context.Context, string, http.Header, int, int) (int, http.Header, []byte, error)

func (f fixtureGetter) Get(ctx context.Context, url string, headers http.Header, size, redirects int) (int, http.Header, []byte, error) {
	return f(ctx, url, headers, size, redirects)
}
func TestPostgresRSSConditionalFetchAndStableRepoll(t *testing.T) {
	db := inboxDatabase(t)
	nonce, err := inboxLeaseToken()
	if err != nil {
		t.Fatal(err)
	}
	feed := "https://" + nonce + ".publisher.example/rss"
	at := time.Date(2026, 10, 7, 0, 0, 0, 0, time.UTC)
	calls := 0
	t.Cleanup(func() {
		db.Exec("DELETE FROM content_items WHERE publication_site=$1", feed)
		db.Exec("DELETE FROM rss_feed_fetch_metadata WHERE feed_url=$1", feed)
	})
	getter := fixtureGetter(func(_ context.Context, url string, headers http.Header, size, redirects int) (int, http.Header, []byte, error) {
		calls++
		if url != feed || size != 2*1024*1024 || redirects != 5 {
			t.Fatal("request bounds")
		}
		if calls == 2 {
			if headers.Get("If-None-Match") != "fixture-etag" {
				t.Fatal("conditional fetch ETag")
			}
			return 304, http.Header{}, nil, nil
		}
		return 200, http.Header{"Etag": []string{"fixture-etag"}}, []byte(`<rss version="2.0"><channel><title>Fixture</title><item><title>A &amp; B</title><guid>opaque-changing-guid</guid><link>https://publisher.example/story/12345</link><description><![CDATA[<p>Publisher <b>body</b></p>]]></description><pubDate>Tue, 06 Oct 2026 12:00:00 GMT</pubDate></item></channel></rss>`), nil
	})
	ingestion := RSSIngestion{DB: db, HTTP: getter, Now: func() time.Time { return at }, MaximumItems: 20, Retention: time.Hour}
	ctx := context.Background()
	count, err := ingestion.Ingest(ctx, feed)
	if err != nil || count != 1 {
		t.Fatalf("ingest %d %v", count, err)
	}
	count, err = ingestion.Ingest(ctx, feed)
	if err != nil || count != 0 {
		t.Fatalf("conditional ingest %d %v", count, err)
	}
	var title, html string
	if err := db.QueryRow(`SELECT render_json->>'title',render_json->>'contentHtml' FROM content_items WHERE publication_site=$1`, feed).Scan(&title, &html); err != nil {
		t.Fatal(err)
	}
	if title != "A & B" || html != "<p>Publisher <b>body</b></p>" {
		t.Fatalf("publisher fields %q %q", title, html)
	}
	var rows int
	if err := db.QueryRow("SELECT count(*) FROM content_items WHERE publication_site=$1", feed).Scan(&rows); err != nil || rows != 1 {
		t.Fatalf("duplicate rows %d %v", rows, err)
	}
}
