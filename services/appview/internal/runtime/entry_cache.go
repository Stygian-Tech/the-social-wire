package runtime

import (
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"strings"
	"sync"
	"time"
)

type EntryCache struct {
	Service *publicationcore.Service
	ctx     context.Context
	cancel  context.CancelFunc
	mu      sync.Mutex
	closed  bool
	pending map[string]bool
	wg      sync.WaitGroup
}

func NewEntryCache(ctx context.Context, service *publicationcore.Service) *EntryCache {
	work, cancel := context.WithCancel(ctx)
	return &EntryCache{Service: service, ctx: work, cancel: cancel, pending: map[string]bool{}}
}
func (c *EntryCache) Close() { c.mu.Lock(); c.closed = true; c.cancel(); c.mu.Unlock(); c.wg.Wait() }
func publicationID(q appviewcore.EntryQuery) string {
	if q.PublicationATURI != "" {
		return publicationcore.NormalizeATRepoParam(q.PublicationATURI)
	}
	if len(q.ScopeATURIs) > 0 && q.ScopeATURIs[0] != "" {
		return publicationcore.NormalizeATRepoParam(q.ScopeATURIs[0])
	}
	if len(q.SiteURLs) > 0 {
		if normalized := thinappviewcore.NormalizeFeedURL(q.SiteURLs[0]); normalized != nil {
			return thinappviewcore.RSSPublicationID(*normalized)
		}
	}
	if strings.HasPrefix(q.AuthorDID, "did:") {
		return q.AuthorDID
	}
	return ""
}
func (c *EntryCache) Read(ctx context.Context, auth gatewaycore.AuthContext, q appviewcore.EntryQuery, maximum int, at time.Time) (appviewcore.EntryPage, error) {
	if maximum == 0 {
		return c.page(ctx, auth, q, at, false)
	}
	if maximum < 1 || maximum > 500 {
		return appviewcore.EntryPage{}, errors.New("invalid maximum entries")
	}
	q.Cursor = ""
	result := appviewcore.EntryPage{Entries: []appviewcore.Entry{}}
	seen, cursors := map[string]bool{}, map[string]bool{}
	for {
		page, e := c.page(ctx, auth, q, at, false)
		if e != nil {
			return result, e
		}
		for _, entry := range page.Entries {
			if !seen[entry.EntryID] {
				seen[entry.EntryID] = true
				result.Entries = append(result.Entries, entry)
			}
		}
		if len(result.Entries) >= maximum {
			overflow := len(result.Entries) > maximum
			result.Entries = result.Entries[:maximum]
			if overflow || page.Cursor != nil {
				last := result.Entries[maximum-1]
				cursor := (appviewcore.EntryCursor{CreatedAt: last.FeedPositionAt, URI: last.EntryID}).Encode()
				result.Cursor = &cursor
			}
			return result, nil
		}
		if len(page.Entries) == 0 || page.Cursor == nil {
			return result, nil
		}
		if cursors[*page.Cursor] {
			return result, errors.New("entry pagination did not advance")
		}
		cursors[*page.Cursor] = true
		q.Cursor = *page.Cursor
	}
}
func (c *EntryCache) page(ctx context.Context, auth gatewaycore.AuthContext, q appviewcore.EntryQuery, at time.Time, skip bool) (appviewcore.EntryPage, error) {
	cache := c.Service.Cache
	id := publicationID(q)
	eligible := q.Cursor == "" && q.Filter == "all" && id != "" && cache != nil
	if eligible && !skip {
		hit, e := cache.CachedPage(ctx, auth.DID, id, q.Limit, at)
		if e != nil {
			return appviewcore.EntryPage{}, e
		}
		if hit != nil {
			if hit.Stale {
				c.refresh(auth, q, id)
			}
			return hit.Page, nil
		}
	}
	var lease *thinappviewcore.RefreshLease
	if eligible && !skip {
		var e error
		lease, e = cache.Projection.AcquireRefreshLease(ctx, "firstpage", id, 10*time.Second)
		if e != nil {
			if ctx.Err() != nil {
				return appviewcore.EntryPage{}, ctx.Err()
			}
			// Match the disposable Redis store's fail-open rebuild lease. No key
			// is owned, so renewal/release must not touch another holder's lock.
			lease = &thinappviewcore.RefreshLease{TTL: 10 * time.Second}
		}
		if lease == nil {
			timer := time.NewTimer(250 * time.Millisecond)
			select {
			case <-ctx.Done():
				timer.Stop()
				return appviewcore.EntryPage{}, ctx.Err()
			case <-timer.C:
			}
			hit, e := cache.CachedPage(ctx, auth.DID, id, q.Limit, time.Now())
			if e != nil {
				return appviewcore.EntryPage{}, e
			}
			if hit != nil {
				if hit.Stale {
					c.refresh(auth, q, id)
				}
				return hit.Page, nil
			}
		}
	}
	if lease != nil {
		stop := c.renew(ctx, cache.Projection, *lease)
		defer stop()
		defer func() {
			cleanup, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			_ = cache.Projection.ReleaseRefreshLease(cleanup, *lease)
			cancel()
		}()
	}
	page, e := (appviewcore.ContentReader{DB: c.Service.DB}).Entries(ctx, q, at)
	if e != nil {
		return page, e
	}
	if eligible && len(page.Entries) > 0 {
		neutral := page
		neutral.Entries = append([]appviewcore.Entry{}, page.Entries...)
		for i := range neutral.Entries {
			neutral.Entries[i].IsRead = false
		}
		if raw, e := publicationcore.EncodeFirstPage(neutral); e == nil {
			_ = cache.Projection.StoreFirstPage(ctx, auth.DID, id, string(raw), time.Now())
		}
	}
	if id != "" {
		for i := range page.Entries {
			page.Entries[i].PublicationID = &id
		}
	}
	return page, nil
}
func (c *EntryCache) renew(ctx context.Context, cache thinappviewcore.ProjectionCache, lease thinappviewcore.RefreshLease) func() {
	work, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(max(time.Second, lease.TTL/3))
		defer ticker.Stop()
		for {
			select {
			case <-work.Done():
				return
			case <-ticker.C:
				ok, e := cache.RenewRefreshLease(work, lease)
				if e != nil || !ok {
					return
				}
			}
		}
	}()
	return func() { cancel(); <-done }
}
func (c *EntryCache) refresh(auth gatewaycore.AuthContext, q appviewcore.EntryQuery, id string) {
	key := auth.DID + "\x00" + id
	c.mu.Lock()
	if c.closed || c.pending[key] || len(c.pending) >= 64 {
		c.mu.Unlock()
		return
	}
	c.pending[key] = true
	c.wg.Add(1)
	c.mu.Unlock()
	go func() {
		defer c.wg.Done()
		defer func() { c.mu.Lock(); delete(c.pending, key); c.mu.Unlock() }()
		ctx, cancel := context.WithTimeout(c.ctx, 20*time.Second)
		defer cancel()
		cache := c.Service.Cache.Projection
		lease, e := cache.AcquireRefreshLease(ctx, "firstpage", id, 10*time.Second)
		if e != nil || lease == nil {
			return
		}
		stop := c.renew(ctx, cache, *lease)
		defer stop()
		defer func() {
			cleanup, finish := context.WithTimeout(context.Background(), 2*time.Second)
			_ = cache.ReleaseRefreshLease(cleanup, *lease)
			finish()
		}()
		_, _ = c.page(ctx, auth, q, time.Now(), true)
	}()
}
