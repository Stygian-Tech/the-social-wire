package publicationcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"time"
)

type unreadValue struct {
	PublicationID string `json:"publicationId"`
	Count         int    `json:"count"`
}

func (c CacheStore) unread(ctx context.Context, viewer string, ids []string, at time.Time) (map[string]int, *time.Time, bool, error) {
	counts := map[string]int{}
	var earliest *time.Time
	stale := false
	if c.Redis != nil {
		for _, id := range ids {
			hit, e := socialwireredis.LookupValue[unreadValue](ctx, c.Redis, c.Projection.Namespace.Key("unread", nil, []string{viewer, id}), at)
			if e != nil {
				if ctx.Err() != nil {
					return counts, earliest, stale, ctx.Err()
				}
				continue
			}
			if hit.State == socialwireredis.Miss {
				continue
			}
			counts[hit.Envelope.Value.PublicationID] = hit.Envelope.Value.Count
			cached := time.UnixMilli(int64(*hit.Envelope.CachedAt))
			if earliest == nil || cached.Before(*earliest) {
				earliest = &cached
			}
			stale = stale || hit.State == socialwireredis.Stale
		}
		return counts, earliest, stale, nil
	}
	rows, e := c.Projection.DB.QueryContext(ctx, `SELECT publication_id,unread_count,cached_at FROM unread_counts_cache WHERE viewer_did=$1 AND publication_id=ANY($2::text[]) AND expires_at>$3`, viewer, ids, at)
	if e != nil {
		return counts, nil, false, e
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var count int
		var cached time.Time
		if e = rows.Scan(&id, &count, &cached); e != nil {
			return counts, earliest, false, e
		}
		counts[id] = count
		if earliest == nil || cached.Before(*earliest) {
			earliest = &cached
		}
	}
	return counts, earliest, false, rows.Err()
}
func (c CacheStore) storeUnread(ctx context.Context, viewer string, counts map[string]int, at time.Time) error {
	fresh, hard := c.UnreadFresh, c.UnreadHard
	if fresh <= 0 {
		fresh = 2 * time.Minute
	}
	if hard <= 0 {
		hard = 15 * time.Minute
	}
	for id, n := range counts {
		n = max(0, n)
		if c.Redis != nil {
			if e := socialwireredis.StoreValue(ctx, c.Redis, c.Projection.Namespace.Key("unread", nil, []string{viewer, id}), unreadValue{id, n}, socialwireredis.CachePolicy{FreshDuration: fresh, HardDuration: hard}, at); e != nil {
				return e
			}
		} else if _, e := c.Projection.DB.ExecContext(ctx, `INSERT INTO unread_counts_cache(viewer_did,publication_id,unread_count,cached_at,expires_at)VALUES($1,$2,$3,$4,$5)ON CONFLICT(viewer_did,publication_id)DO UPDATE SET unread_count=EXCLUDED.unread_count,cached_at=EXCLUDED.cached_at,expires_at=EXCLUDED.expires_at`, viewer, id, n, at, at.Add(fresh)); e != nil {
			return e
		}
	}
	return nil
}
func (s *Service) CachedCounters(ctx context.Context, viewer string, rows []SidebarRow) (CounterSnapshot, error) {
	if s.Cache == nil || len(rows) == 0 {
		return s.Counters(ctx, viewer, rows, false)
	}
	at := s.Now()
	counts, cachedAt, stale, _ := s.Cache.unread(ctx, viewer, rowIDs(rows), at)
	missing := []SidebarRow{}
	for _, row := range rows {
		if _, ok := counts[row.PublicationID]; !ok {
			missing = append(missing, row)
		}
	}
	var lease *thinappviewcore.RefreshLease
	if len(missing) > 0 {
		lease, _ = s.Cache.Projection.AcquireRefreshLease(ctx, "unread", viewer, 10*time.Second)
		if lease == nil {
			if e := waitContext(ctx, 250*time.Millisecond); e != nil {
				return CounterSnapshot{}, e
			}
			additional, otherAt, otherStale, _ := s.Cache.unread(ctx, viewer, rowIDs(missing), s.Now())
			for id, n := range additional {
				counts[id] = n
			}
			if otherAt != nil {
				cachedAt = otherAt
			}
			stale = stale || otherStale
			missing = []SidebarRow{}
			for _, row := range rows {
				if _, ok := counts[row.PublicationID]; !ok {
					missing = append(missing, row)
				}
			}
		}
	}
	reconstructed := CounterSnapshot{Counts: map[string]int{}, MissingPublicationIDs: []string{}}
	if len(missing) > 0 {
		var e error
		reconstructed, e = s.Counters(ctx, viewer, missing, false)
		if e != nil {
			if ctx.Err() != nil {
				return CounterSnapshot{}, ctx.Err()
			}
			reconstructed = CounterSnapshot{Counts: map[string]int{}, Generation: counterGeneration(at), CountedAt: at, Accuracy: "estimated", Dirty: true, MissingPublicationIDs: rowIDs(missing)}
			for _, row := range missing {
				reconstructed.Counts[row.PublicationID] = 0
			}
		}
		for id, n := range reconstructed.Counts {
			if _, ok := counts[id]; !ok {
				counts[id] = n
			}
		}
		_ = s.Cache.storeUnread(ctx, viewer, reconstructed.Counts, s.Now())
	}
	if lease != nil {
		release, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
		_ = s.Cache.Projection.ReleaseRefreshLease(release, *lease)
		cancel()
	}
	snapshot := reconstructed
	snapshot.Counts = counts
	snapshot.Accuracy = "estimated"
	if cachedAt == nil && reconstructed.Accuracy == "exact" {
		snapshot.Accuracy = "exact"
	}
	if cachedAt != nil {
		snapshot.Generation = max(snapshot.Generation, counterGeneration(*cachedAt))
		if cachedAt.After(snapshot.CountedAt) {
			snapshot.CountedAt = *cachedAt
		}
	}
	if snapshot.CountedAt.IsZero() {
		snapshot.CountedAt = at
	}
	if stale || snapshot.Dirty || len(snapshot.MissingPublicationIDs) > 0 {
		s.launch("unread-refresh:"+viewer, func(work context.Context) { _, _ = s.RefreshCounters(work, viewer, rows) })
	}
	return snapshot, nil
}
func (s *Service) RefreshCounters(ctx context.Context, viewer string, rows []SidebarRow) (CounterSnapshot, error) {
	var lease *thinappviewcore.RefreshLease
	if s.Cache != nil {
		lease, _ = s.Cache.Projection.AcquireRefreshLease(ctx, "unread", viewer, 10*time.Second)
		if lease == nil {
			return s.Counters(ctx, viewer, rows, false)
		}
	}
	stop := s.renew(ctx, lease)
	defer stop()
	scopes := []appviewcore.PublicationScope{}
	for _, row := range rows {
		scopes = append(scopes, row.AppViewScope.ReadScope(row.PublicationID))
	}
	snapshot, e := (CounterStore{DB: s.DB}).Refresh(ctx, viewer, scopes, s.Now())
	if e == nil && s.Cache != nil {
		_ = s.Cache.storeUnread(ctx, viewer, snapshot.Counts, s.Now())
	}
	return snapshot, e
}
