package publicationcore

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestResolverCancelsAndJoinsRSSAlternates(t *testing.T) {
	blocked := make(chan struct{})
	joined := make(chan struct{})
	getter := getterFunc(func(ctx context.Context, target string, h http.Header, max, redirects int) (int, http.Header, []byte, error) {
		u, _ := url.Parse(target)
		switch u.Path {
		case "/":
			return 200, nil, []byte(`<link rel="alternate" type="application/rss+xml" href="/fast.xml"><link rel="alternate" href="/slow.xml">`), nil
		case "/fast.xml":
			<-blocked
			return 200, nil, []byte(`<rss><channel/></rss>`), nil
		case "/slow.xml":
			close(blocked)
			<-ctx.Done()
			close(joined)
			return 0, nil, nil, ctx.Err()
		default:
			return 404, nil, nil, nil
		}
	})
	r := Resolver{HTTP: getter}
	u, _ := url.Parse("https://publisher.social/")
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	feed := r.discoverRSS(ctx, u)
	if feed != "https://publisher.social/fast.xml" {
		t.Fatal(feed)
	}
	select {
	case <-joined:
	default:
		t.Fatal("losing request still running")
	}
}
func TestAlternateURLsAndHTTPBodiesAreBounded(t *testing.T) {
	base, _ := url.Parse("https://publisher.social/articles/post")
	feeds := alternateFeeds(`<link rel="alternate" href="../rss.xml"><link rel="stylesheet" href="/style.css">`, base)
	if len(feeds) != 1 || feeds[0] != "https://publisher.social/rss.xml" {
		t.Fatal(feeds)
	}
	r := Resolver{HTTP: getterFunc(func(ctx context.Context, target string, h http.Header, max, redirects int) (int, http.Header, []byte, error) {
		if h.Get("Authorization") != "" || h.Get("DPoP") != "" || max > 1024*1024 || redirects != 5 {
			t.Error("resolver request violated bounds")
		}
		if strings.Contains(target, ".well-known") {
			return 200, nil, []byte("at://did:plc:publisher/site.standard.publication/a\n"), nil
		}
		return 404, nil, nil, nil
	})}
	response := r.https(context.Background(), "https://publisher.social/article?q=1")
	if response.Result == nil || response.Result.Kind != "standard-site" {
		t.Fatalf("resolution %+v", response)
	}
}
