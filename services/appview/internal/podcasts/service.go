package podcasts

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

type Repository interface {
	GetRecord(context.Context, string, string, string, string) (*gatewaycore.RepoRecord, error)
	ListRecords(context.Context, string, string, string, int, bool) (gatewaycore.RepoPage, error)
	ResolvePDS(context.Context, string) (string, error)
}
type Service struct {
	Store         *podcastcore.Store
	Repo          Repository
	Fetcher       MediaFetcher
	BridgeEnabled bool
	Now           func() time.Time
	Embedded      *EmbeddedArtwork
	Directory     *Directory
}
type ResolveResponse struct {
	Show     podcastcore.Show      `json:"show"`
	Episodes []podcastcore.Episode `json:"episodes"`
	Shows    *[]podcastcore.Show   `json:"shows,omitempty"`
}
type HTTPError struct {
	Status  int
	Message string
}

func (e HTTPError) Error() string                { return e.Message }
func httpError(status int, message string) error { return HTTPError{status, message} }
func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}
func (s *Service) Close() {
	if s.Directory != nil {
		s.Directory.Close()
	}
}
func atParts(uri string) (did, collection, rkey string, ok bool) {
	if !strings.HasPrefix(uri, "at://") {
		return "", "", "", false
	}
	parts := strings.Split(strings.TrimPrefix(uri, "at://"), "/")
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
		return "", "", "", false
	}
	return parts[0], parts[1], parts[2], true
}
func recordValues(record *gatewaycore.RepoRecord) map[string]any {
	if record == nil {
		return nil
	}
	result := map[string]any{}
	for key, raw := range record.Value {
		var v any
		if json.Unmarshal(raw, &v) == nil {
			result[key] = v
		}
	}
	return result
}
func (s *Service) Record(ctx context.Context, uri string) (map[string]any, error) {
	did, collection, rkey, ok := atParts(uri)
	if !ok {
		return nil, httpError(400, "Unsupported Podcast Source")
	}
	record, err := s.Repo.GetRecord(ctx, did, collection, rkey, "")
	if err != nil {
		return nil, err
	}
	return recordValues(record), nil
}
func (s *Service) Resolve(ctx context.Context, raw string) (ResolveResponse, error) {
	if strings.HasPrefix(raw, "at://") {
		did, collection, _, ok := atParts(raw)
		episodeCollection := podcastcore.ProtocolCollections[collection]
		if !ok || episodeCollection == "" {
			return ResolveResponse{}, httpError(400, "Unsupported Podcast Source")
		}
		record, err := s.Record(ctx, raw)
		if err != nil {
			return ResolveResponse{}, err
		}
		if record == nil {
			return ResolveResponse{}, httpError(400, "Unsupported Podcast Source")
		}
		base, err := s.Repo.ResolvePDS(ctx, did)
		if err != nil {
			return ResolveResponse{}, err
		}
		show, err := podcastcore.ProtocolShow(raw, record, base)
		if err != nil {
			return ResolveResponse{}, err
		}
		episodes := []podcastcore.Episode{}
		cursor := ""
		seen := map[string]bool{}
		for {
			page, err := s.Repo.ListRecords(ctx, did, episodeCollection, cursor, 100, false)
			if err != nil {
				return ResolveResponse{}, err
			}
			for _, record := range page.Records {
				if e := podcastcore.ProtocolEpisode(record.URI, recordValues(&record), show, base); e != nil {
					episodes = append(episodes, *e)
				}
			}
			if page.Cursor == "" {
				break
			}
			if seen[page.Cursor] {
				return ResolveResponse{}, ErrSourceUnavailable
			}
			seen[page.Cursor] = true
			cursor = page.Cursor
		}
		if show.Guid != nil {
			existing, err := s.Store.Show(ctx, "guid:"+*show.Guid)
			if err != nil {
				return ResolveResponse{}, err
			}
			if existing != nil && existing.ID != show.ID {
				if err := s.Store.Alias(ctx, show.ID, existing.ID, "show"); err != nil {
					return ResolveResponse{}, err
				}
				existing.SourceURI = show.SourceURI
				existing.EpisodeCollection = show.EpisodeCollection
				for i := range episodes {
					episodes[i].ShowID = existing.ID
				}
				show = *existing
			}
		}
		return s.persistResolved(ctx, show, episodes)
	}
	if strings.HasPrefix(raw, "did:") || !strings.Contains(raw, "/") && !strings.HasPrefix(raw, "https:") && !strings.HasPrefix(raw, "http:") {
		collections := []string{}
		for collection := range podcastcore.ProtocolCollections {
			collections = append(collections, collection)
		}
		sort.Strings(collections)
		choices := []podcastcore.Show{}
		for _, collection := range collections {
			cursor := ""
			seen := map[string]bool{}
			for {
				page, err := s.Repo.ListRecords(ctx, raw, collection, cursor, 100, false)
				if err != nil {
					return ResolveResponse{}, err
				}
				for _, record := range page.Records {
					if show, err := podcastcore.ProtocolShow(record.URI, recordValues(&record), ""); err == nil {
						choices = append(choices, show)
					}
				}
				if page.Cursor == "" {
					break
				}
				if seen[page.Cursor] {
					return ResolveResponse{}, ErrSourceUnavailable
				}
				seen[page.Cursor] = true
				cursor = page.Cursor
			}
		}
		if len(choices) == 0 {
			return ResolveResponse{}, httpError(404, "No Podcast Shows Found")
		}
		source := choices[0].ID
		if choices[0].SourceURI != nil {
			source = *choices[0].SourceURI
		}
		resolved, err := s.Resolve(ctx, source)
		if err != nil {
			return ResolveResponse{}, err
		}
		resolved.Shows = &choices
		return resolved, nil
	}
	normalized := thinappviewcore.NormalizeFeedURL(raw)
	if !podcastcore.PublicRSSURLAllowed(raw) || normalized == nil {
		return ResolveResponse{}, httpError(400, "Only Public HTTPS Podcast Feeds Are Supported")
	}
	body, err := s.Fetcher.Fetch(ctx, *normalized, FetchOptions{MaximumBytes: 32 * 1024 * 1024, ValidateURL: podcastcore.PublicRSSURLAllowed})
	if err != nil {
		return ResolveResponse{}, err
	}
	show, episodes, err := podcastcore.ParseRSS(body, *normalized)
	if err != nil {
		return ResolveResponse{}, err
	}
	if len(episodes) == 0 {
		return ResolveResponse{}, httpError(400, "No Audio Episodes Found")
	}
	existing, err := s.Store.Show(ctx, *normalized)
	if err != nil {
		return ResolveResponse{}, err
	}
	if existing == nil && show.Guid != nil {
		existing, err = s.Store.Show(ctx, "guid:"+*show.Guid)
		if err != nil {
			return ResolveResponse{}, err
		}
	}
	if existing != nil {
		show.ID = existing.ID
		if show.Guid == nil {
			show.Guid = existing.Guid
		}
		show.SourceURI = existing.SourceURI
		show.EpisodeCollection = existing.EpisodeCollection
		show.SourceKind = existing.SourceKind
		if len(show.Hosts) == 0 {
			show.Hosts = existing.Hosts
		}
		for i := range episodes {
			episodes[i].ShowID = existing.ID
		}
	}
	return s.persistResolved(ctx, show, episodes)
}
func (s *Service) persistResolved(ctx context.Context, show podcastcore.Show, episodes []podcastcore.Episode) (ResolveResponse, error) {
	enriched := s.Enrich(ctx, episodes[:min(len(episodes), 50)], nil, false, false)
	episodes = append(enriched, episodes[min(len(episodes), 50):]...)
	if err := s.Store.Upsert(ctx, show, episodes); err != nil {
		return ResolveResponse{}, err
	}
	ids := make([]string, len(episodes))
	for i, e := range episodes {
		ids[i] = e.ID
	}
	aliases, err := s.Store.CanonicalEpisodeIDs(ctx, ids)
	if err != nil {
		return ResolveResponse{}, err
	}
	for i := range episodes {
		if canonical, ok := aliases[episodes[i].ID]; ok {
			episodes[i].ID = canonical
		}
		episodes[i] = visibleEpisode(episodes[i])
	}
	return ResolveResponse{Show: show, Episodes: episodes}, nil
}
func (s *Service) Episode(ctx context.Context, id, viewer string) (*podcastcore.Episode, error) {
	if podcastcore.IsPrivateID(id) {
		return s.Store.PrivateEpisode(ctx, viewer, id)
	}
	return s.Store.Episode(ctx, id)
}
func (s *Service) Show(ctx context.Context, id, viewer string) (*podcastcore.Show, error) {
	if podcastcore.IsPrivateID(id) {
		return s.Store.PrivateShow(ctx, viewer, id)
	}
	return s.Store.Show(ctx, id)
}
func visibleEpisode(e podcastcore.Episode) podcastcore.Episode {
	if e.Visibility != nil && *e.Visibility == "private" {
		e = podcastcore.VisibleEpisode(e)
	}
	e.ChapterSourceURL = nil
	return e
}
func (s *Service) ResolvePrivate(ctx context.Context, viewer, raw string, existingOnly bool) (ResolveResponse, error) {
	if s.Store.Private == nil {
		return ResolveResponse{}, podcastcore.ErrPrivateStorageUnavailable
	}
	source := strings.TrimSpace(raw)
	if !podcastcore.PrivateURLAllowed(source) {
		return ResolveResponse{}, httpError(400, "Private Feeds Require HTTPS Without URL Userinfo")
	}
	result, err := s.resolvePrivate(ctx, viewer, source, existingOnly)
	if err == nil {
		return result, nil
	}
	if errors.Is(err, podcastcore.ErrPrivateStorageUnavailable) {
		return ResolveResponse{}, err
	}
	if errors.Is(err, podcastcore.ErrNotFound) {
		return ResolveResponse{}, httpError(404, "Private Podcast Subscription Not Found")
	}
	return ResolveResponse{}, httpError(400, "Private Podcast Feed Could Not Be Loaded")
}
func (s *Service) resolvePrivate(ctx context.Context, viewer, source string, existingOnly bool) (ResolveResponse, error) {
	body, err := s.Fetcher.Fetch(ctx, source, FetchOptions{MaximumBytes: 32 * 1024 * 1024, ValidateURL: podcastcore.PrivateURLAllowed})
	if err != nil {
		return ResolveResponse{}, err
	}
	show, episodes, err := podcastcore.ParseRSS(body, source)
	if err != nil {
		return ResolveResponse{}, err
	}
	if len(episodes) == 0 {
		return ResolveResponse{}, ErrSourceUnavailable
	}
	show, episodes = podcastcore.ScopePrivate(viewer, source, show, episodes)
	enriched := s.Enrich(ctx, episodes[:min(len(episodes), 50)], &viewer, false, false)
	episodes = append(enriched, episodes[min(len(episodes), 50):]...)
	if err := s.Store.SavePrivateCatalog(ctx, viewer, source, show, episodes, existingOnly); err != nil {
		return ResolveResponse{}, err
	}
	for i := range episodes {
		episodes[i] = podcastcore.VisibleEpisode(episodes[i])
	}
	return ResolveResponse{Show: podcastcore.VisibleShow(show), Episodes: episodes}, nil
}
func (s *Service) RefreshPrivate(ctx context.Context, viewer, showID string) (ResolveResponse, error) {
	feed, err := s.Store.PrivateFeed(ctx, viewer, showID)
	if err != nil {
		return ResolveResponse{}, err
	}
	if feed == nil {
		return ResolveResponse{}, httpError(404, "Private Podcast Subscription Not Found")
	}
	return s.ResolvePrivate(ctx, viewer, feed.URL, true)
}
func (s *Service) PrivateShows(ctx context.Context, viewer string) ([]podcastcore.Show, error) {
	feeds, err := s.Store.StalePrivateFeeds(ctx, viewer, 2)
	if err != nil {
		return nil, err
	}
	var wg sync.WaitGroup
	for _, feed := range feeds {
		wg.Go(func() { _, _ = s.ResolvePrivate(ctx, viewer, feed, true) })
	}
	wg.Wait()
	shows, err := s.Store.PrivateShows(ctx, viewer)
	if err != nil {
		return nil, err
	}
	for i := range shows {
		shows[i] = podcastcore.VisibleShow(shows[i])
	}
	return shows, nil
}
func (s *Service) Enrich(ctx context.Context, episodes []podcastcore.Episode, viewer *string, persist, embedded bool) []podcastcore.Episode {
	output := append([]podcastcore.Episode{}, episodes...)
	deadline := time.Now().Add(10 * time.Second)
	for offset := 0; offset < min(len(episodes), 100) && time.Now().Before(deadline); offset += 8 {
		var wg sync.WaitGroup
		for i := offset; i < min(offset+8, len(episodes), 100); i++ {
			wg.Go(func() {
				e := episodes[i]
				if len(e.Chapters) == 0 && e.ChapterSourceURL != nil {
					timeout := min(3*time.Second, time.Until(deadline))
					if timeout > 0 {
						if data, err := s.Fetcher.Fetch(ctx, *e.ChapterSourceURL, FetchOptions{MaximumBytes: 2 * 1024 * 1024, Timeout: timeout}); err == nil {
							e.Chapters = podcastcore.ParseChapters(data, e.DurationSeconds)
						}
					}
				}
				if e.ShowArtworkURL == nil {
					v := ""
					if viewer != nil {
						v = *viewer
					}
					if show, err := s.Show(ctx, e.ShowID, v); err == nil && show != nil {
						e.ShowArtworkURL = show.ArtworkURL
					}
				}
				if embedded && len(e.Chapters) > 0 && s.Embedded != nil {
					missing := false
					for _, c := range e.Chapters {
						missing = missing || c.ArtworkURL == nil
					}
					if missing {
						v := ""
						if viewer != nil {
							v = *viewer
						}
						if images, err := s.Embedded.Artwork(ctx, e, v, s.Fetcher); err == nil {
							e = EnrichEmbeddedArtwork(e, images)
						}
					}
				}
				if persist && !reflect.DeepEqual(e, episodes[i]) {
					_ = s.Store.UpdateMetadata(ctx, e, viewer)
				}
				output[i] = e
			})
		}
		wg.Wait()
	}
	return output
}
