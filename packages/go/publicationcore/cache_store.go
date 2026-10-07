package publicationcore

import (
	"context"
	"database/sql"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"time"
)

type CacheStore struct {
	Projection                thinappviewcore.ProjectionCache
	Redis                     *socialwireredis.CacheClient
	SidebarFresh, SidebarHard time.Duration
}
type CachedSnapshot struct {
	Snapshot            BootstrapSnapshot
	CachedAt, ExpiresAt time.Time
	Stale               bool
}

func (c CacheStore) Lookup(ctx context.Context, viewer string, at time.Time, includeExpired bool) (*CachedSnapshot, error) {
	var raw string
	var cached, expires time.Time
	stale := false
	if c.Redis != nil {
		hit, e := socialwireredis.LookupValue[string](ctx, c.Redis, c.Projection.Namespace.Key("sidebar", nil, []string{viewer}), at)
		if e != nil {
			return nil, e
		}
		if hit.State == socialwireredis.Miss {
			return nil, nil
		}
		raw = hit.Envelope.Value
		cached = time.UnixMilli(int64(*hit.Envelope.CachedAt))
		expires = time.UnixMilli(int64(*hit.Envelope.FreshUntil))
		stale = hit.State == socialwireredis.Stale
	} else {
		e := c.Projection.DB.QueryRowContext(ctx, `SELECT json_body::text,cached_at,expires_at FROM sidebar_projection_cache WHERE viewer_did=$1`, viewer).Scan(&raw, &cached, &expires)
		if e == sql.ErrNoRows {
			return nil, nil
		}
		if e != nil {
			return nil, e
		}
		if !includeExpired && !expires.After(at) {
			return nil, nil
		}
		stale = !expires.After(at)
	}
	snapshot, e := decodeSnapshot(raw)
	if e != nil || snapshot.Version != 1 {
		return nil, nil
	}
	return &CachedSnapshot{snapshot, cached, expires, stale}, nil
}
func (c CacheStore) Store(ctx context.Context, viewer string, snapshot BootstrapSnapshot, at time.Time) error {
	raw, e := snapshotJSON(snapshot)
	if e != nil {
		return e
	}
	fresh, hard := c.SidebarFresh, c.SidebarHard
	if fresh == 0 {
		fresh = time.Hour
	}
	if hard == 0 {
		hard = 6 * time.Hour
	}
	if c.Redis != nil {
		return socialwireredis.StoreValue(ctx, c.Redis, c.Projection.Namespace.Key("sidebar", nil, []string{viewer}), raw, socialwireredis.CachePolicy{FreshDuration: fresh, HardDuration: hard}, at)
	}
	_, e = c.Projection.DB.ExecContext(ctx, `INSERT INTO sidebar_projection_cache(viewer_did,json_body,cached_at,expires_at)VALUES($1,$2::jsonb,$3,$4)ON CONFLICT(viewer_did)DO UPDATE SET json_body=EXCLUDED.json_body,cached_at=EXCLUDED.cached_at,expires_at=EXCLUDED.expires_at`, viewer, raw, at, at.Add(fresh))
	return e
}
func (c CacheStore) InvalidateSidebar(ctx context.Context, viewer string) error {
	if c.Redis != nil {
		return c.Redis.Commands.Delete(ctx, []string{c.Projection.Namespace.Key("sidebar", nil, []string{viewer})})
	}
	_, e := c.Projection.DB.ExecContext(ctx, `DELETE FROM sidebar_projection_cache WHERE viewer_did=$1`, viewer)
	return e
}
