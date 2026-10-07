package podcasts

import (
	"context"
	"encoding/base64"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
)

type assetRoundTrip func(*http.Request) (*http.Response, error)

func (f assetRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func assetRequest(path, viewer string) *http.Request {
	r := httptest.NewRequest("GET", path, nil)
	if viewer != "" {
		r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: viewer}))
	}
	return r
}
func TestArtworkCacheCoalescesWithoutSharingPrivateOwnership(t *testing.T) {
	cache := &EmbeddedArtwork{}
	episode := podcastcore.Episode{AudioURL: "https://podcast.audiohost.com/file.mp3"}
	var calls atomic.Int32
	entered, release := make(chan struct{}), make(chan struct{})
	fetch := func(ctx context.Context, _ string, _ int, _ string) ([]byte, error) {
		if calls.Add(1) == 1 {
			close(entered)
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-release:
			return []byte("unsupported"), nil
		}
	}
	canceled, cancel := context.WithCancel(context.Background())
	first := make(chan error, 1)
	go func() { _, e := cache.artwork(canceled, episode, "one", fetch); first <- e }()
	<-entered
	second := make(chan error, 1)
	go func() { _, e := cache.artwork(context.Background(), episode, "two", fetch); second <- e }()
	cancel()
	if e := <-first; e != context.Canceled {
		t.Fatal(e)
	}
	close(release)
	if e := <-second; e != nil {
		t.Fatal(e)
	}
	if calls.Load() != 1 {
		t.Fatal("public prefix did not coalesce", calls.Load())
	}
	episode.Visibility = artworkPointer("private")
	for _, viewer := range []string{"one", "two", "one"} {
		if _, e := cache.artwork(context.Background(), episode, viewer, fetch); e != nil {
			t.Fatal(e)
		}
	}
	if calls.Load() != 3 {
		t.Fatal("private owners shared cached prefix", calls.Load())
	}
	if _, e := cache.artwork(context.Background(), episode, "", fetch); e == nil {
		t.Fatal("private prefix accessible anonymously")
	}
}
func TestArtworkCacheBoundsConcurrentPrefixes(t *testing.T) {
	cache := &EmbeddedArtwork{}
	release := make(chan struct{})
	entered := make(chan struct{}, 8)
	fetch := func(ctx context.Context, _ string, _ int, _ string) ([]byte, error) {
		entered <- struct{}{}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-release:
			return []byte("unsupported"), nil
		}
	}
	var wg sync.WaitGroup
	for n := 0; n < 8; n++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			_, _ = cache.artwork(context.Background(), podcastcore.Episode{AudioURL: string(rune('a' + n))}, "", fetch)
		}(n)
	}
	for n := 0; n < 8; n++ {
		<-entered
	}
	if _, e := cache.artwork(context.Background(), podcastcore.Episode{AudioURL: "ninth"}, "", fetch); e == nil {
		t.Fatal("concurrent prefix limit exceeded")
	}
	close(release)
	wg.Wait()
}
func TestEmbeddedEnrichmentMatchesOnlyMissingChapterArt(t *testing.T) {
	existing := "https://publisher.images.com/image.png"
	episode := podcastcore.Episode{ID: "episode&id", Chapters: []podcastcore.Chapter{{StartSeconds: 0}, {StartSeconds: 2, ArtworkURL: &existing}, {StartSeconds: 4}}}
	enriched := EnrichEmbeddedArtwork(episode, []podcastcore.ID3ChapterArtwork{{StartSeconds: .49}, {StartSeconds: 2}, {StartSeconds: 4.5}})
	if enriched.Chapters[0].ArtworkURL == nil || !strings.Contains(*enriched.Chapters[0].ArtworkURL, "episode%26id") || enriched.Chapters[1].ArtworkURL == nil || *enriched.Chapters[1].ArtworkURL != existing || enriched.Chapters[2].ArtworkURL != nil || episode.Chapters[0].ArtworkURL != nil {
		t.Fatal(enriched, episode)
	}
}
func TestImageRouteChecksOwnershipAndRasterBytes(t *testing.T) {
	png, _ := base64.StdEncoding.DecodeString("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5X8AAAAASUVORK5CYII=")
	target := "https://publisher.images.com/image"
	var fetched atomic.Int32
	data := png
	assets := Assets{Show: func(ctx context.Context, id, viewer string) (*podcastcore.Show, error) {
		if viewer != "owner" {
			return nil, nil
		}
		return &podcastcore.Show{ArtworkURL: &target}, nil
	}, Fetcher: MediaFetcher{Client: &http.Client{Transport: assetRoundTrip(func(r *http.Request) (*http.Response, error) {
		fetched.Add(1)
		if r.Header.Get("Authorization") != "" || r.Header.Get("DPoP") != "" {
			t.Fatal("OAuth leaked to image source")
		}
		return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(string(data)))}, nil
	})}}}
	for _, viewer := range []string{"", "other"} {
		w := httptest.NewRecorder()
		assets.Image(w, assetRequest("/v1/podcasts/image?showId=private-podcast:show", viewer))
		if w.Code != 401 && w.Code != 404 {
			t.Fatal(w.Code)
		}
	}
	if fetched.Load() != 0 {
		t.Fatal("unowned source fetched")
	}
	w := httptest.NewRecorder()
	assets.Image(w, assetRequest("/v1/podcasts/image?showId=show", "owner"))
	if w.Code != 200 || w.Header().Get("Content-Type") != "image/png" || w.Header().Get("Cache-Control") != "private, no-store" || w.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Fatal(w.Code, w.Header())
	}
	data = []byte("<svg><script>active</script></svg>")
	w = httptest.NewRecorder()
	assets.Image(w, assetRequest("/v1/podcasts/image?showId=show", "owner"))
	if w.Code != 415 {
		t.Fatal(w.Code)
	}
	w = httptest.NewRecorder()
	assets.Image(w, assetRequest("/v1/podcasts/image?showId=show&index=1000", "owner"))
	if w.Code != 400 {
		t.Fatal(w.Code)
	}
}
func TestPublicClipAssetsVerifyLiveRecordAndDoNotFollowWorkerRedirects(t *testing.T) {
	id := "12345678-1234-1234-1234-123456789abc"
	published := true
	var fetched atomic.Int32
	assets := Assets{WorkerURL: "http://podcast-worker.railway.internal", Secret: "worker-secret", Clip: func(ctx context.Context, clipID string, viewer *string, public bool) (*podcastcore.Clip, error) {
		if clipID != id || !public || viewer != nil {
			t.Fatal("publication scope drift")
		}
		return &podcastcore.Clip{ID: id, Status: "complete", PublishedURI: artworkPointer("at://did:plc:fixture/app.thesocialwire.podcast.clip/key")}, nil
	}, PublishedRecordMatches: func(context.Context, podcastcore.Clip) (bool, error) { return published, nil }, WorkerClient: &http.Client{Transport: assetRoundTrip(func(r *http.Request) (*http.Response, error) {
		fetched.Add(1)
		if r.URL.Path != "/assets/"+id+"/audio.m4a" || r.Header.Get("X-Podcast-Media-Secret") != "worker-secret" || r.Header.Get("Range") != "bytes=0-1" || r.Header.Get("Authorization") != "" {
			t.Fatal(r.URL.Path, r.Header)
		}
		return &http.Response{StatusCode: 206, Header: http.Header{"Content-Type": []string{"audio/mp4"}, "Content-Range": []string{"bytes 0-1/10"}, "Accept-Ranges": []string{"bytes"}}, Body: io.NopCloser(strings.NewReader("ab"))}, nil
	})}}
	r := assetRequest("/v1/podcasts/public/assets?clipId="+id+"&format=audio", "")
	r.Header.Set("Range", "bytes=0-1")
	w := httptest.NewRecorder()
	assets.PublicAsset(w, r)
	if w.Code != 206 || w.Body.String() != "ab" || w.Header().Get("Content-Range") != "bytes 0-1/10" {
		t.Fatal(w.Code, w.Header(), w.Body.String())
	}
	published = false
	w = httptest.NewRecorder()
	assets.PublicAsset(w, r)
	if w.Code != 404 || fetched.Load() != 1 {
		t.Fatal("removed PDS record still served", w.Code, fetched.Load())
	}
}
func TestMediaRedirectRevalidatesOriginWithoutCredentials(t *testing.T) {
	var calls int
	fetcher := MediaFetcher{Client: &http.Client{Transport: assetRoundTrip(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Header.Get("Range") != "bytes=10-20" || r.Header.Get("Authorization") != "" {
			t.Fatal(r.Header)
		}
		return &http.Response{StatusCode: 302, Header: http.Header{"Location": []string{"http://127.0.0.1/private"}}, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if reply, e := streamPodcastMedia(ctx, fetcher, "https://podcast.audiohost.com/episode", "bytes=10-20"); e == nil || reply != nil || calls != 1 {
		t.Fatal("unsafe redirect followed", calls, e)
	}
}

func TestAssetRoutesDenyAnonymousDiscoveryAndExposeStorageAvailabilitySafely(t *testing.T) {
	assets := Assets{Show: func(context.Context, string, string) (*podcastcore.Show, error) {
		return nil, podcastcore.ErrPrivateStorageUnavailable
	}, Episode: func(context.Context, string, string) (*podcastcore.Episode, error) {
		return nil, podcastcore.ErrPrivateStorageUnavailable
	}, Clip: func(context.Context, string, *string, bool) (*podcastcore.Clip, error) {
		return nil, podcastcore.ErrPrivateStorageUnavailable
	}}
	for _, route := range []struct {
		path    string
		handler http.HandlerFunc
	}{{"/v1/podcasts/image?showId=private-podcast:show", assets.Image}, {"/v1/podcasts/media?episodeId=private-podcast:episode", assets.Media}, {"/v1/podcasts/assets?clipId=clip", assets.PrivateAsset}} {
		w := httptest.NewRecorder()
		route.handler(w, assetRequest(route.path, gatewaycore.AnonymousDiscoveryDID))
		if w.Code != 401 {
			t.Fatal(route.path, w.Code)
		}
		w = httptest.NewRecorder()
		route.handler(w, assetRequest(route.path, "owner"))
		if w.Code != 503 || !strings.Contains(w.Body.String(), "Private Podcast Storage Is Unavailable") {
			t.Fatal(route.path, w.Code, w.Body.String())
		}
	}
}

type canceledAssetBody struct{ ctx context.Context }

func (b canceledAssetBody) Read([]byte) (int, error) { <-b.ctx.Done(); return 0, b.ctx.Err() }
func (b canceledAssetBody) Close() error             { return nil }
func TestMediaIdleReadIsCanceledAndCloseStopsTimer(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	body := newIdleMediaBody(canceledAssetBody{ctx}, cancel, 10*time.Millisecond)
	done := make(chan error, 1)
	go func() { _, err := body.Read(make([]byte, 1)); done <- err }()
	select {
	case err := <-done:
		if err != context.Canceled {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("idle source did not cancel")
	}
	if err := body.Close(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel = context.WithCancel(context.Background())
	body = newIdleMediaBody(io.NopCloser(strings.NewReader("ab")), cancel, time.Hour)
	if err := body.Close(); err != nil || ctx.Err() != context.Canceled {
		t.Fatal(err, ctx.Err())
	}
}
