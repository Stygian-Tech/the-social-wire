package podcasts

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
	"io"
	"net/http"
	"sync"
	"time"
)

// Media streams through the pinned public transport and revalidates every
// redirect. It never attaches the viewer's OAuth or worker-secret credentials.
func (a *Assets) Media(w http.ResponseWriter, r *http.Request) {
	viewer, ok := assetViewer(w, r)
	if !ok {
		return
	}
	id := r.URL.Query().Get("episodeId")
	if id == "" || a.Episode == nil {
		assetError(w, 404, "Episode not found")
		return
	}
	episode, e := a.Episode(r.Context(), id, viewer)
	if assetStoreFailure(w, e) {
		return
	}
	if episode == nil {
		assetError(w, 404, "Episode not found")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 6*time.Hour)
	defer cancel()
	reply, e := streamPodcastMedia(ctx, a.Fetcher, episode.AudioURL, r.Header.Get("Range"))
	if e != nil {
		assetError(w, 502, "Podcast media could not be loaded")
		return
	}
	defer reply.Body.Close()
	streamAssetResponse(w, reply)
}
func streamPodcastMedia(ctx context.Context, fetcher MediaFetcher, raw, rangeHeader string) (*http.Response, error) {
	requestCtx, cancel := context.WithCancel(ctx)
	current := raw
	client := fetcher.client()
	for hop := 0; hop < 6; hop++ {
		if !podcastcore.PrivateURLAllowed(current) {
			cancel()
			return nil, ErrSourceUnavailable
		}
		request, e := http.NewRequestWithContext(requestCtx, "GET", current, nil)
		if e != nil {
			cancel()
			return nil, ErrSourceUnavailable
		}
		if rangeHeader != "" {
			request.Header.Set("Range", rangeHeader)
		}
		reply, e := client.Do(request)
		if e != nil {
			cancel()
			return nil, ErrSourceUnavailable
		}
		if redirect(reply.StatusCode) && reply.Header.Get("Location") != "" {
			reply.Body.Close()
			current, e = nextURL(current, reply.Header.Get("Location"))
			if e != nil {
				cancel()
				return nil, ErrSourceUnavailable
			}
			continue
		}
		reply.Body = newIdleMediaBody(reply.Body, cancel, 60*time.Second)
		return reply, nil
	}
	cancel()
	return nil, ErrSourceUnavailable
}

// A stalled source is canceled independently of the six-hour playback budget.
// Wrapping Read also prevents io.Copy from bypassing the read-idle guard.
type idleMediaBody struct {
	body   io.ReadCloser
	cancel context.CancelFunc
	timer  *time.Timer
	idle   time.Duration
	mu     sync.Mutex
	closed bool
}

func newIdleMediaBody(body io.ReadCloser, cancel context.CancelFunc, idle time.Duration) *idleMediaBody {
	result := &idleMediaBody{body: body, cancel: cancel, idle: idle}
	result.timer = time.AfterFunc(idle, cancel)
	return result
}
func (b *idleMediaBody) Read(data []byte) (int, error) {
	n, err := b.body.Read(data)
	if n > 0 {
		b.mu.Lock()
		if !b.closed {
			b.timer.Reset(b.idle)
		}
		b.mu.Unlock()
	}
	return n, err
}
func (b *idleMediaBody) Close() error {
	b.mu.Lock()
	if !b.closed {
		b.closed = true
		b.timer.Stop()
		b.cancel()
	}
	b.mu.Unlock()
	return b.body.Close()
}
