package podcasts

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
)

func ptr[T any](v T) *T { return &v }

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestDirectoryQueryPrivacyAndCandidateArtwork(t *testing.T) {
	for _, query := range []string{"Primary Technology", "AI + Technology", "Café podcasts"} {
		if _, err := ValidateDirectoryQuery(podcastcore.SearchRequest{Query: query, Scope: ptr("directory")}); err != nil {
			t.Fatal(query, err)
		}
	}
	for _, query := range []string{"https://publisher.com/rss?token=secret", "www.example.com/rss", "name@example.com", "token: something", "bearer proof", "one%2520two", "line\nnew", "abcdefghijklmnopqrstuvwxyz1234567890"} {
		if _, err := ValidateDirectoryQuery(podcastcore.SearchRequest{Query: query, Scope: ptr("directory")}); !errors.Is(err, ErrDirectoryInvalidQuery) {
			t.Fatal("leaked query", query, err)
		}
	}
	rows, err := ParseDirectory([]byte(`{"resultCount":3,"results":[{"kind":"podcast","trackId":9007199254740993,"collectionName":"Primary Technology","feedUrl":"https://feeds.transistor.fm/primary-technology","artworkUrl600":"http://images.transistor.fm/old.png","artworkUrl100":"https://images.transistor.fm/current.png"},{"kind":"podcast","trackId":2,"collectionName":"Bad","feedUrl":"https://example.com/private?token=secret"},{"kind":"podcast","trackId":3,"collectionName":"Duplicate","feedUrl":"https://feeds.transistor.fm/primary-technology"}]}`))
	if err != nil || len(rows) != 1 || rows[0].ID != "9007199254740993" || rows[0].ArtworkURL == nil || *rows[0].ArtworkURL != "https://images.transistor.fm/current.png" {
		t.Fatal(rows, err)
	}
	if _, err := ParseDirectory([]byte(`{"resultCount":2,"results":[]}`)); !errors.Is(err, ErrDirectoryUnavailable) {
		t.Fatal("partial provider result accepted")
	}
}
func TestDirectoryCoalescingBudgetAndIndependentCancellation(t *testing.T) {
	directory := NewDirectory(MediaFetcher{})
	defer directory.Close()
	directory.MaximumRequests = 1
	started, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	directory.Fetch = func(ctx context.Context, query string) ([]byte, error) {
		calls.Add(1)
		close(started)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-release:
			return []byte(`{"resultCount":0,"results":[]}`), nil
		}
	}
	request := podcastcore.SearchRequest{Query: "Primary Technology", Scope: ptr("directory")}
	ctx, cancel := context.WithCancel(context.Background())
	first := make(chan error, 1)
	go func() { _, err := directory.Search(ctx, request); first <- err }()
	<-started
	cancel()
	if err := <-first; !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if _, err := directory.Search(context.Background(), podcastcore.SearchRequest{Query: "Other Show", Scope: ptr("directory")}); !errors.Is(err, ErrDirectoryBusy) {
		t.Fatal("provider budget bypassed", err)
	}
	close(release)
	result, err := directory.Search(context.Background(), request)
	if err != nil || result.DirectoryLimit == nil || calls.Load() != 1 {
		t.Fatal(result, err, calls.Load())
	}
	if _, err := directory.Search(context.Background(), request); err != nil || calls.Load() != 1 {
		t.Fatal("cache miss", err)
	}
}
func TestMediaRedirectPolicyBodyBudgetAndDeadline(t *testing.T) {
	var calls atomic.Int32
	fetcher := MediaFetcher{Client: &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		if r.URL.Path == "/redirect" {
			return &http.Response{StatusCode: 302, Header: http.Header{"Location": {"https://other.publisher.com/body"}}, Body: io.NopCloser(strings.NewReader(""))}, nil
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"application/json; charset=utf-8"}}, Body: io.NopCloser(strings.NewReader("12345"))}, nil
	})}}
	target := "https://publisher.com/redirect"
	if _, err := fetcher.Fetch(context.Background(), target, FetchOptions{MaximumBytes: 10, ValidateURL: func(u string) bool { return u == target }}); err == nil || calls.Load() != 1 {
		t.Fatal("fixed provider policy escaped", err, calls.Load())
	}
	if _, err := fetcher.Fetch(context.Background(), "https://publisher.com/body", FetchOptions{MaximumBytes: 4}); err == nil {
		t.Fatal("oversized body accepted")
	}
	body, err := fetcher.Fetch(context.Background(), "https://publisher.com/body", FetchOptions{MaximumBytes: 5, ContentType: "application/json"})
	if err != nil || string(body) != "12345" {
		t.Fatal(string(body), err)
	}
	slow := MediaFetcher{Client: &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) { <-r.Context().Done(); return nil, r.Context().Err() })}}
	if _, err := slow.Fetch(context.Background(), "https://publisher.com/body", FetchOptions{MaximumBytes: 5, Timeout: time.Millisecond}); err == nil {
		t.Fatal("deadline ignored")
	}
}

func TestDirectoryRejectsTrailingProviderData(t *testing.T) {
	for _, suffix := range []string{`{}`, `true`, `invalid`} {
		if _, err := ParseDirectory([]byte(`{"resultCount":0,"results":[]}` + suffix)); !errors.Is(err, ErrDirectoryUnavailable) {
			t.Fatal("accepted trailing provider data", suffix, err)
		}
	}
	if _, err := ParseDirectory([]byte("{\"resultCount\":0,\"results\":[]} \n")); err != nil {
		t.Fatal(err)
	}
}
func TestDirectoryCachedCandidatesAreIsolated(t *testing.T) {
	directory := NewDirectory(MediaFetcher{})
	defer directory.Close()
	var calls atomic.Int32
	directory.Fetch = func(context.Context, string) ([]byte, error) {
		calls.Add(1)
		return []byte(`{"resultCount":1,"results":[{"kind":"podcast","trackId":1,"collectionName":"Show","description":"Original","feedUrl":"https://publisher.com/feed","artworkUrl600":"https://publisher.com/art.png"}]}`), nil
	}
	request := podcastcore.SearchRequest{Query: "Show", Scope: ptr("directory")}
	first, err := directory.Search(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	*first.Candidates[0].Description = "Changed"
	*first.Candidates[0].ArtworkURL = "https://other.com/art.png"
	second, err := directory.Search(context.Background(), request)
	if err != nil || calls.Load() != 1 || *second.Candidates[0].Description != "Original" || *second.Candidates[0].ArtworkURL != "https://publisher.com/art.png" {
		t.Fatal("shared cache was mutated", second, err)
	}
}
