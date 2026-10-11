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

func TestNewsResolverRejectsDirectPodcastFeed(t *testing.T) {
	r := Resolver{HTTP: getterFunc(func(ctx context.Context, target string, h http.Header, max, redirects int) (int, http.Header, []byte, error) {
		if target == "https://publisher.social/podcast.xml" {
			return 200, nil, []byte(`<rss><channel><item><enclosure url="https://publisher.social/episode.mp3" type="audio/mpeg"/></item></channel></rss>`), nil
		}
		return 404, nil, nil, nil
	})}
	response := r.Resolve(context.Background(), "https://publisher.social/podcast.xml")
	if response.Result != nil || response.Error == nil || !strings.Contains(*response.Error, "Podcasts") {
		t.Fatalf("podcast became News subscription candidate: %+v", response)
	}
}

func TestNewsResolverSkipsPodcastAlternate(t *testing.T) {
	r := Resolver{HTTP: getterFunc(func(ctx context.Context, target string, h http.Header, max, redirects int) (int, http.Header, []byte, error) {
		switch target {
		case "https://publisher.social", "https://publisher.social/":
			return 200, nil, []byte(`<link rel="alternate" type="application/rss+xml" href="/podcast.xml"><link rel="alternate" type="application/rss+xml" href="/news.xml">`), nil
		case "https://publisher.social/podcast.xml":
			return 200, nil, []byte(`<rss><channel><item><enclosure url="https://publisher.social/episode.mp3"/></item></channel></rss>`), nil
		case "https://publisher.social/news.xml":
			return 200, nil, []byte(`<rss><channel><item><title>News</title></item></channel></rss>`), nil
		default:
			return 404, nil, nil, nil
		}
	})}
	response := r.Resolve(context.Background(), "https://publisher.social/")
	if response.Result == nil || response.Result.FeedURL == nil || *response.Result.FeedURL != "https://publisher.social/news.xml" {
		t.Fatalf("wrong News feed: %+v", response)
	}
}
