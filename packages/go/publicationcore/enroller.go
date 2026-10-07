package publicationcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewworkercore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"math/rand/v2"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Enroller struct {
	DB                                          *sql.DB
	PDS                                         *thinappviewcore.PDSClient
	HTTP                                        thinappviewcore.PublicGetter
	Repo                                        Repository
	Projection                                  *appviewworkercore.EventProjectorRuntime
	RSS                                         *thinappviewcore.RSSIngestion
	MaximumAuthors, MaximumRecords, Concurrency int
	Wait                                        func(context.Context, time.Duration) error
	Now                                         func() time.Time
}

func waitContext(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
func (e *Enroller) Enroll(ctx context.Context, auth gatewaycore.AuthContext, authors, feeds []string, recent bool) (int, error) {
	maxAuthors, concurrency := e.MaximumAuthors, e.Concurrency
	if maxAuthors <= 0 {
		maxAuthors = 500
	}
	if concurrency <= 0 {
		concurrency = 4
	}
	seen := map[string]bool{}
	unique := []string{}
	for _, author := range authors {
		author = strings.TrimSpace(author)
		if author != "" && !seen[author] {
			seen[author] = true
			unique = append(unique, author)
		}
	}
	sort.Strings(unique)
	if len(unique) > maxAuthors {
		unique = unique[:maxAuthors]
	}
	slots := make(chan struct{}, concurrency)
	var wg sync.WaitGroup
	var mu sync.Mutex
	count := 0
	errs := []error{}
	rate := time.NewTicker(time.Second / time.Duration(concurrency*10))
	defer rate.Stop()
	for _, author := range unique {
		select {
		case slots <- struct{}{}:
		case <-ctx.Done():
			wg.Wait()
			return count, ctx.Err()
		}
		wg.Add(1)
		go func(author string) {
			defer wg.Done()
			defer func() { <-slots }()
			n, err := e.author(ctx, author, recent, rate.C)
			mu.Lock()
			count += n
			if err != nil {
				errs = append(errs, err)
			}
			mu.Unlock()
		}(author)
	}
	wg.Wait()
	if ctx.Err() != nil {
		return count, ctx.Err()
	}
	if !recent && len(errs) > 0 {
		return count, fmt.Errorf("PDS enrollment incomplete: %w", errors.Join(errs...))
	}
	if e.RSS != nil && len(feeds) > 0 {
		n, err := e.IngestSubscriptions(ctx, auth, feeds)
		count += n
		if err != nil {
			return count, err
		}
	}
	return count, nil
}
func (e *Enroller) IngestSubscriptions(ctx context.Context, auth gatewaycore.AuthContext, priority []string) (int, error) {
	if e.RSS == nil {
		return 0, errors.New("RSS ingestion unavailable")
	}
	records, err := listAll(ctx, e.Repo, auth.DID, thinappviewcore.RSSSubscriptionCollection, 20)
	if err != nil {
		return 0, err
	}
	allowed := map[string]bool{}
	for _, r := range records {
		v := recordValue(r)
		if strings.EqualFold(text(v, "category"), "podcast") {
			continue
		}
		source := strings.ToLower(text(v, "sourceType"))
		if source != "" && source != "rss" {
			continue
		}
		if feed := thinappviewcore.NormalizeFeedURL(text(v, "feedUrl")); feed != nil {
			allowed[*feed] = true
		}
	}
	feeds := []string{}
	if len(priority) == 0 {
		for feed := range allowed {
			feeds = append(feeds, feed)
		}
	} else {
		for _, raw := range priority {
			if feed := thinappviewcore.NormalizeFeedURL(raw); feed != nil && allowed[*feed] {
				feeds = append(feeds, *feed)
			}
		}
	}
	sort.Strings(feeds)
	total := 0
	for _, feed := range feeds {
		n, err := e.RSS.Ingest(ctx, feed)
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}
func (e *Enroller) author(ctx context.Context, did string, recent bool, rate <-chan time.Time) (int, error) {
	if !strings.HasPrefix(did, "did:plc:") && !strings.HasPrefix(did, "did:web:") || did == thinappviewcore.RSSAuthorDID {
		return 0, errors.New("invalid enrollment author")
	}
	base, err := e.PDS.Resolve(ctx, did)
	if err != nil || base == "" {
		return 0, errors.New("PDS resolution unavailable")
	}
	budget := e.MaximumRecords
	if budget <= 0 {
		budget = 2000
	}
	indexed := 0
	for _, collection := range []string{"site.standard.document", "site.standard.entry"} {
		cursor := ""
		seen := map[string]bool{}
		reverse := true
		limit := 50
		if collection == "site.standard.document" {
			limit = 1
		} // Hosted PDS currently caps documents at one; match verified Go recovery policy.
		for {
			if budget <= 0 {
				return indexed, errors.New("record cap reached")
			}
			select {
			case <-ctx.Done():
				return indexed, ctx.Err()
			case <-rate:
			}
			params := url.Values{"repo": {did}, "collection": {collection}, "limit": {strconv.Itoa(min(limit, budget))}}
			if reverse {
				params.Set("reverse", "true")
			}
			if cursor != "" {
				params.Set("cursor", cursor)
			}
			body, usedReverse, err := e.page(ctx, base, params, reverse)
			reverse = usedReverse
			if err != nil {
				return indexed, err
			}
			var page struct {
				Records []struct {
					URI, CID string
					Value    json.RawMessage
				}
				Cursor json.RawMessage
			}
			if json.Unmarshal(body, &page) != nil || page.Records == nil {
				return indexed, errors.New("malformed PDS page")
			}
			for _, row := range page.Records {
				if budget <= 0 {
					return indexed, errors.New("record cap reached")
				}
				budget--
				prefix := "at://" + did + "/" + collection + "/"
				key := strings.TrimPrefix(row.URI, prefix)
				if !strings.HasPrefix(row.URI, prefix) || key == "" || strings.Contains(key, "/") || row.CID == "" {
					return indexed, errors.New("malformed PDS record")
				}
				if err = e.Projection.Commit(ctx, did, collection, key, row.CID, "create", "", row.Value, time.Time{}, base); err != nil {
					return indexed, err
				}
				indexed++
			}
			next := ""
			if len(page.Cursor) > 0 && string(page.Cursor) != "null" {
				if json.Unmarshal(page.Cursor, &next) != nil || strings.TrimSpace(next) == "" || len(next) > 4096 {
					return indexed, errors.New("malformed PDS cursor")
				}
			}
			if next != "" && (next == cursor || seen[next] || len(page.Records) == 0) {
				return indexed, errors.New("PDS cursor did not advance")
			}
			if recent || next == "" {
				break
			}
			seen[next] = true
			cursor = next
		}
	}
	return indexed, nil
}
func (e *Enroller) page(ctx context.Context, base string, params url.Values, reverse bool) ([]byte, bool, error) {
	getter := e.HTTP
	if getter == nil {
		getter = thinappviewcore.PublicHTTP{}
	}
	wait := e.Wait
	if wait == nil {
		wait = waitContext
	}
	for attempt := 0; ; {
		request, cancel := context.WithTimeout(ctx, 20*time.Second)
		status, headers, body, err := getter.Get(request, strings.TrimRight(base, "/")+"/xrpc/com.atproto.repo.listRecords?"+params.Encode(), http.Header{"Accept": {"application/json"}}, 8*1024*1024, 0)
		cancel()
		if err != nil {
			return nil, reverse, err
		}
		if status == 400 && reverse {
			var reason struct{ Error, Message string }
			json.Unmarshal(body, &reason)
			message := strings.ToLower(reason.Message)
			if strings.EqualFold(reason.Error, "InvalidRequest") && strings.Contains(message, "reverse") && strings.Contains(message, "not supported") {
				reverse = false
				params.Del("reverse")
				continue
			}
		}
		if status == 429 && attempt < 3 {
			attempt++
			delay := retryDelay(headers.Get("Retry-After"), attempt, time.Now(), .1+rand.Float64()*.15)
			if err = wait(ctx, delay); err != nil {
				return nil, reverse, err
			}
			continue
		}
		if status != 200 {
			return nil, reverse, fmt.Errorf("PDS listRecords status %d", status)
		}
		return body, reverse, nil
	}
}
func retryDelay(raw string, attempt int, at time.Time, jitter float64) time.Duration {
	base := time.Second * time.Duration(1<<max(0, attempt-1))
	if seconds, err := strconv.ParseUint(strings.TrimSpace(raw), 10, 64); err == nil {
		if seconds >= 30 {
			base = 30 * time.Second
		} else {
			base = time.Duration(seconds) * time.Second
		}
	} else if date, err := http.ParseTime(raw); err == nil {
		base = max(0, date.Sub(at))
	}
	return min(30*time.Second, time.Duration(float64(base)*(1+max(0, min(.25, jitter)))))
}
func NewEnroller(db *sql.DB, repo Repository, pds *thinappviewcore.PDSClient, getter thinappviewcore.PublicGetter, cache *thinappviewcore.ProjectionCache, env map[string]string) *Enroller {
	integer := func(key string, fallback int) int {
		n, e := strconv.Atoi(strings.TrimSpace(env[key]))
		if e != nil || n <= 0 {
			return fallback
		}
		return n
	}
	retention := time.Duration(integer("THIN_APPVIEW_CONTENT_TTL_SECONDS", 30*86400)) * time.Second
	rss := &thinappviewcore.RSSIngestion{DB: db, HTTP: getter, Cache: cache, MaximumItems: integer("THIN_APPVIEW_MAX_RSS_ITEMS_PER_FEED", 200), Retention: retention}
	projector := &appviewworkercore.EventProjectorRuntime{DB: db, PDS: pds, Cache: cache, RSS: rss, Counters: thinappviewcore.CounterStore{DB: db}, Retention: retention}
	return &Enroller{DB: db, Repo: repo, PDS: pds, HTTP: getter, Projection: projector, RSS: rss, MaximumAuthors: integer("THIN_APPVIEW_MAX_ENROLL_AUTHORS", 500), MaximumRecords: integer("THIN_APPVIEW_MAX_ENROLL_RECORDS_PER_AUTHOR", 2000), Concurrency: integer("THIN_APPVIEW_MAX_ENROLL_CONCURRENCY", 4)}
}
