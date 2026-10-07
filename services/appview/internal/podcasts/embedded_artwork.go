package podcasts

import (
	"bytes"
	"context"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
)

type artworkKey struct{ scope, url string }
type artworkEntry struct {
	expires time.Time
	images  []podcastcore.ID3ChapterArtwork
}
type artworkPending struct {
	done   chan struct{}
	images []podcastcore.ID3ChapterArtwork
	err    error
}

// EmbeddedArtwork bounds both cached images and concurrent metadata prefixes to
// eight episodes. Private URLs remain scoped to their owning viewer in memory.
type EmbeddedArtwork struct {
	mu      sync.Mutex
	cached  map[artworkKey]artworkEntry
	pending map[artworkKey]*artworkPending
	Now     func() time.Time
}

func (c *EmbeddedArtwork) clock() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}
func cloneArtwork(images []podcastcore.ID3ChapterArtwork) []podcastcore.ID3ChapterArtwork {
	out := make([]podcastcore.ID3ChapterArtwork, len(images))
	for i, v := range images {
		out[i] = v
		out[i].Data = bytes.Clone(v.Data)
	}
	return out
}
func (c *EmbeddedArtwork) Artwork(ctx context.Context, episode podcastcore.Episode, viewer string, fetcher MediaFetcher) ([]podcastcore.ID3ChapterArtwork, error) {
	return c.artwork(ctx, episode, viewer, func(ctx context.Context, raw string, maximum int, rangeHeader string) ([]byte, error) {
		return fetcher.Fetch(ctx, raw, FetchOptions{MaximumBytes: maximum, Timeout: 8 * time.Second, Headers: http.Header{"Range": []string{rangeHeader}, "User-Agent": []string{"TheSocialWirePodcastMetadata/1.0"}}, AllowPartial: true, MaximumRedirects: artworkPointer(10)})
	})
}
func (c *EmbeddedArtwork) artwork(ctx context.Context, episode podcastcore.Episode, viewer string, fetch func(context.Context, string, int, string) ([]byte, error)) ([]podcastcore.ID3ChapterArtwork, error) {
	scope := "public"
	if episode.Visibility != nil && *episode.Visibility == "private" {
		if viewer == "" {
			return nil, ErrSourceUnavailable
		}
		scope = "private:" + viewer
	}
	key := artworkKey{scope, episode.AudioURL}
	c.mu.Lock()
	if c.cached == nil {
		c.cached = map[artworkKey]artworkEntry{}
		c.pending = map[artworkKey]*artworkPending{}
	}
	at := c.clock()
	for k, v := range c.cached {
		if !v.expires.After(at) {
			delete(c.cached, k)
		}
	}
	if hit, ok := c.cached[key]; ok {
		images := cloneArtwork(hit.images)
		c.mu.Unlock()
		return images, nil
	}
	if pending := c.pending[key]; pending != nil {
		c.mu.Unlock()
		return awaitArtwork(ctx, pending)
	}
	if len(c.cached)+len(c.pending) >= 8 {
		var oldest *artworkKey
		var expires time.Time
		for k, v := range c.cached {
			if oldest == nil || v.expires.Before(expires) {
				copy := k
				oldest = &copy
				expires = v.expires
			}
		}
		if oldest != nil {
			delete(c.cached, *oldest)
		}
	}
	if len(c.cached)+len(c.pending) >= 8 {
		c.mu.Unlock()
		return nil, ErrSourceUnavailable
	}
	pending := &artworkPending{done: make(chan struct{})}
	c.pending[key] = pending
	c.mu.Unlock()
	// Joining viewers do not inherit another request's cancellation. The detached
	// prefix fetch still has a strict overall budget and remains capacity bounded.
	fetchCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 16*time.Second)
	go func() {
		defer cancel()
		images, err := fetchID3Artwork(fetchCtx, episode.AudioURL, fetch)
		c.mu.Lock()
		defer c.mu.Unlock()
		delete(c.pending, key)
		pending.images = images
		pending.err = err
		if err == nil {
			c.cached[key] = artworkEntry{c.clock().Add(5 * time.Minute), images}
		}
		close(pending.done)
	}()
	return awaitArtwork(ctx, pending)
}
func awaitArtwork(ctx context.Context, pending *artworkPending) ([]podcastcore.ID3ChapterArtwork, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-pending.done:
		return cloneArtwork(pending.images), pending.err
	}
}
func fetchID3Artwork(ctx context.Context, raw string, fetch func(context.Context, string, int, string) ([]byte, error)) ([]podcastcore.ID3ChapterArtwork, error) {
	header, err := fetch(ctx, raw, 10, "bytes=0-9")
	if err != nil {
		return nil, err
	}
	size, ok := podcastcore.ID3TagByteCount(header)
	if !ok {
		return []podcastcore.ID3ChapterArtwork{}, nil
	}
	tag, err := fetch(ctx, raw, size, "bytes=0-"+strconv.Itoa(size-1))
	if err != nil {
		return nil, err
	}
	return podcastcore.ParseID3ChapterArtwork(tag), nil
}
func EnrichEmbeddedArtwork(episode podcastcore.Episode, images []podcastcore.ID3ChapterArtwork) podcastcore.Episode {
	episode.Chapters = append([]podcastcore.Chapter{}, episode.Chapters...)
	for i, chapter := range episode.Chapters {
		if chapter.ArtworkURL != nil {
			continue
		}
		for _, image := range images {
			if math.Abs(image.StartSeconds-chapter.StartSeconds) < .5 {
				query := url.Values{"episodeId": []string{episode.ID}, "kind": []string{"chapter"}, "index": []string{strconv.Itoa(i)}}
				episode.Chapters[i].ArtworkURL = artworkPointer("/v1/podcasts/image?" + query.Encode())
				break
			}
		}
	}
	return episode
}

func artworkPointer[T any](value T) *T { return &value }
