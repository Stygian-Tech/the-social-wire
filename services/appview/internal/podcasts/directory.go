package podcasts

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/rivo/uniseg"
	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
)

var (
	ErrDirectoryInvalidRequest = errors.New("invalid podcast directory request")
	ErrDirectoryInvalidQuery   = errors.New("invalid podcast directory query")
	ErrDirectoryBusy           = errors.New("podcast directory busy")
	ErrDirectoryUnavailable    = errors.New("podcast directory unavailable")
)
var directoryPatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)(https?\s*:|at://|www\.|\b[a-z0-9.-]+\.[a-z]{2,}/|[?&=]|\b(?:bearer|dpop)\s+|\b(?:token|password|secret|api[-_ ]?key|authorization)\s*:)`),
	regexp.MustCompile(`%[0-9A-Fa-f]{2}`), regexp.MustCompile(`[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}`), regexp.MustCompile(`\b[A-Za-z0-9_+/-]{32,}\b`),
}

func ValidateDirectoryQuery(r podcastcore.SearchRequest) (string, error) {
	if r.Validate() != nil {
		return "", ErrDirectoryInvalidRequest
	}
	if r.Scope == nil || *r.Scope != "directory" || r.Cursor != nil || r.ShowID != nil || r.Kind != nil && *r.Kind != "all" && *r.Kind != "shows" {
		return "", ErrDirectoryInvalidRequest
	}
	query := strings.TrimSpace(r.Query)
	decoded, err := url.PathUnescape(query)
	if err != nil {
		decoded = query
	}
	if strings.Contains(decoded, "@") || strings.ContainsAny(decoded, "\r\n\u0085\u2028\u2029") {
		return "", ErrDirectoryInvalidQuery
	}
	for _, pattern := range directoryPatterns {
		if pattern.MatchString(decoded) {
			return "", ErrDirectoryInvalidQuery
		}
	}
	return query, nil
}
func safeDirectoryURL(raw string) *string {
	if uniseg.GraphemeClusterCount(raw) > 4096 || !podcastcore.PrivateURLAllowed(raw) {
		return nil
	}
	u, err := url.Parse(raw)
	if err != nil || strings.Contains(raw, "#") {
		return nil
	}
	host := strings.ToLower(u.Hostname())
	if !strings.Contains(host, ".") || strings.Contains(host, ":") || host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") || strings.HasSuffix(host, ".internal") {
		return nil
	}
	labels := strings.Split(host, ".")
	last := labels[len(labels)-1]
	if last == "" {
		return nil
	}
	for _, r := range last {
		if !unicode.IsLetter(r) {
			return nil
		}
	}
	return &raw
}
func ParseDirectory(data []byte) ([]podcastcore.DirectoryCandidate, error) {
	var root struct {
		ResultCount *int             `json:"resultCount"`
		Results     []map[string]any `json:"results"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if decoder.Decode(&root) != nil || root.ResultCount == nil || *root.ResultCount < 0 || root.Results == nil || len(root.Results) > 1000 || *root.ResultCount != len(root.Results) {
		return nil, ErrDirectoryUnavailable
	}
	if decoder.Decode(new(any)) != io.EOF {
		return nil, ErrDirectoryUnavailable
	}
	seen, identifiers := map[string]bool{}, map[string]bool{}
	result := []podcastcore.DirectoryCandidate{}
	for _, row := range root.Results {
		kind, _ := row["kind"].(string)
		feed, _ := row["feedUrl"].(string)
		name, _ := row["collectionName"].(string)
		if _, exists := row["collectionName"]; !exists {
			name, _ = row["trackName"].(string)
		}
		if kind != "podcast" || !podcastcore.PublicRSSURLAllowed(feed) || safeDirectoryURL(feed) == nil || strings.TrimSpace(name) == "" || seen[feed] {
			continue
		}
		seen[feed] = true
		idNumber, ok := directoryNumber(row["trackId"])
		if !ok {
			idNumber, _ = directoryNumber(row["collectionId"])
		}
		id := podcastcore.Identity(feed)
		if idNumber > 0 {
			id = strconv.FormatInt(idNumber, 10)
		}
		if identifiers[id] {
			continue
		}
		identifiers[id] = true
		arts := []string{}
		for _, key := range []string{"artworkUrl600", "artworkUrl100", "artworkUrl60"} {
			if s, ok := row[key].(string); ok {
				arts = append(arts, s)
			}
		}
		var artwork *string
		for _, raw := range arts {
			if artwork = safeDirectoryURL(raw); artwork != nil {
				break
			}
		}
		if artwork == nil {
			for _, raw := range arts {
				u, err := url.Parse(raw)
				if err == nil && strings.EqualFold(u.Scheme, "http") {
					u.Scheme = "https"
					if artwork = safeDirectoryURL(u.String()); artwork != nil {
						break
					}
				}
			}
		}
		var description *string
		if s, ok := row["description"].(string); ok {
			s = graphemePrefix(s, 4096)
			description = &s
		}
		result = append(result, podcastcore.DirectoryCandidate{Provider: "podcastindex", ID: id, Title: graphemePrefix(name, 512), Description: description, ArtworkURL: artwork, FeedURL: feed})
		if len(result) == 50 {
			break
		}
	}
	return result, nil
}
func graphemePrefix(s string, n int) string {
	g := uniseg.NewGraphemes(s)
	end := 0
	for i := 0; i < n && g.Next(); i++ {
		_, end = g.Positions()
	}
	return s[:end]
}
func directoryNumber(value any) (int64, bool) {
	if n, ok := value.(json.Number); ok {
		if i, err := n.Int64(); err == nil {
			return i, true
		}
		if f, err := n.Float64(); err == nil {
			return int64(f), true
		}
	}
	if b, ok := value.(bool); ok {
		if b {
			return 1, true
		}
		return 0, true
	}
	return 0, false
}

type directoryCache struct {
	expires    time.Time
	candidates []podcastcore.DirectoryCandidate
}
type directoryPending struct {
	done       chan struct{}
	candidates []podcastcore.DirectoryCandidate
	err        error
}
type Directory struct {
	mu                                 sync.Mutex
	ctx                                context.Context
	cancel                             context.CancelFunc
	wg                                 sync.WaitGroup
	cache                              map[string]directoryCache
	pending                            map[string]*directoryPending
	requests                           []time.Time
	Now                                func() time.Time
	MaximumRequests, MaximumConcurrent int
	Fetch                              func(context.Context, string) ([]byte, error)
}

func NewDirectory(fetcher MediaFetcher) *Directory {
	ctx, cancel := context.WithCancel(context.Background())
	d := &Directory{ctx: ctx, cancel: cancel, cache: map[string]directoryCache{}, pending: map[string]*directoryPending{}, Now: time.Now, MaximumRequests: 20, MaximumConcurrent: 2}
	d.Fetch = func(ctx context.Context, query string) ([]byte, error) {
		target := "https://api.podcastindex.org/search?term=" + strings.ReplaceAll(url.QueryEscape(query), "+", "%20")
		return fetcher.Fetch(ctx, target, FetchOptions{MaximumBytes: 2 * 1024 * 1024, Timeout: 8 * time.Second, ValidateURL: func(raw string) bool { return raw == target }, Headers: http.Header{"User-Agent": {"TheSocialWire/1.0 (+https://thesocialwire.app)"}, "Accept": {"application/json"}}, ContentType: "application/json"})
	}
	return d
}
func (d *Directory) Close() { d.cancel(); d.wg.Wait() }
func (d *Directory) Search(ctx context.Context, r podcastcore.SearchRequest) (podcastcore.SearchResponse, error) {
	query, err := ValidateDirectoryQuery(r)
	if err != nil {
		return podcastcore.SearchResponse{}, err
	}
	key := podcastcore.Identity(strings.ToLower(query))
	d.mu.Lock()
	at := d.Now()
	for k, v := range d.cache {
		if !v.expires.After(at) {
			delete(d.cache, k)
		}
	}
	if v, ok := d.cache[key]; ok {
		d.mu.Unlock()
		return directoryResult(v.candidates, r.Limit), nil
	}
	pending := d.pending[key]
	if pending == nil {
		kept := d.requests[:0]
		for _, t := range d.requests {
			if at.Sub(t) < 60*time.Second {
				kept = append(kept, t)
			}
		}
		d.requests = kept
		if len(d.requests) >= d.MaximumRequests || len(d.pending) >= d.MaximumConcurrent || d.ctx.Err() != nil {
			d.mu.Unlock()
			return podcastcore.SearchResponse{}, ErrDirectoryBusy
		}
		d.requests = append(d.requests, at)
		pending = &directoryPending{done: make(chan struct{})}
		d.pending[key] = pending
		d.wg.Add(1)
		go func(p *directoryPending) {
			defer d.wg.Done()
			data, err := d.Fetch(d.ctx, query)
			var candidates []podcastcore.DirectoryCandidate
			if err == nil {
				candidates, err = ParseDirectory(data)
			}
			if err != nil {
				err = ErrDirectoryUnavailable
			}
			d.mu.Lock()
			defer d.mu.Unlock()
			p.candidates, p.err = candidates, err
			delete(d.pending, key)
			if err == nil {
				if len(d.cache) >= 128 {
					oldest := ""
					var expires time.Time
					for k, v := range d.cache {
						if oldest == "" || v.expires.Before(expires) {
							oldest, expires = k, v.expires
						}
					}
					delete(d.cache, oldest)
				}
				d.cache[key] = directoryCache{d.Now().Add(300 * time.Second), candidates}
			}
			close(p.done)
		}(pending)
	}
	d.mu.Unlock()
	select {
	case <-ctx.Done():
		return podcastcore.SearchResponse{}, ctx.Err()
	case <-pending.done:
		if pending.err != nil {
			return podcastcore.SearchResponse{}, pending.err
		}
		return directoryResult(pending.candidates, r.Limit), nil
	}
}
func directoryResult(candidates []podcastcore.DirectoryCandidate, limit *int) podcastcore.SearchResponse {
	n := 50
	if limit != nil {
		n = min(*limit, 50)
	}
	n = min(n, len(candidates))
	directoryLimit := 50
	result := append([]podcastcore.DirectoryCandidate{}, candidates[:n]...)
	// Responses must not expose optional-string pointers retained by the shared cache.
	for i := range result {
		if result[i].Description != nil {
			result[i].Description = pointer(*result[i].Description)
		}
		if result[i].ArtworkURL != nil {
			result[i].ArtworkURL = pointer(*result[i].ArtworkURL)
		}
	}
	return podcastcore.SearchResponse{Shows: []podcastcore.Show{}, Episodes: []podcastcore.Episode{}, Candidates: result, DirectoryLimit: &directoryLimit}
}
