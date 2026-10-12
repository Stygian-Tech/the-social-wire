package podcasts

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestPodcastResolutionRejectsNewsRSS(t *testing.T) {
	service := Service{Fetcher: MediaFetcher{Client: &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": {"application/rss+xml"}}, Body: io.NopCloser(strings.NewReader(`<rss><channel><title>News Publication</title><item><title>Article</title><link>https://publisher.social/article</link><enclosure url="https://publisher.social/photo.jpg" type="image/jpeg"/></item></channel></rss>`))}, nil
	})}}}
	// No store is configured: article feeds must be rejected before saving any
	// podcast catalog or private subscription records.
	t.Run("public", func(t *testing.T) {
		_, err := service.Resolve(context.Background(), "https://publisher.social/news.xml")
		var response HTTPError
		if !errors.As(err, &response) || response.Status != http.StatusBadRequest || response.Message != "No Audio Episodes Found" {
			t.Fatalf("news feed accepted by podcast resolver: %v", err)
		}
	})
	t.Run("private", func(t *testing.T) {
		_, err := service.resolvePrivate(context.Background(), "did:plc:viewer", "https://publisher.social/news.xml?token=private", false)
		if !errors.Is(err, ErrSourceUnavailable) {
			t.Fatalf("news feed accepted by private podcast resolver: %v", err)
		}
	})
}
