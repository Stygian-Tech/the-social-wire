package thinappviewcore

import (
	"context"
	"database/sql"
	"fmt"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"time"
)

type ProjectionCache struct {
	DB                            *sql.DB
	Redis                         redis.Cmdable
	Namespace                     socialwireredis.KeyNamespace
	FirstPageFresh, FirstPageHard time.Duration
	LockTelemetry                 func(operation, outcome string)
}

func (c ProjectionCache) deletePattern(ctx context.Context, pattern string) error {
	var cursor uint64
	for {
		keys, next, err := c.Redis.Scan(ctx, cursor, pattern, 250).Result()
		if err != nil {
			return err
		}
		for start := 0; start < len(keys); start += 250 {
			end := min(start+250, len(keys))
			if err := c.Redis.Del(ctx, keys[start:end]...).Err(); err != nil {
				return err
			}
		}
		cursor = next
		if cursor == 0 {
			return nil
		}
	}
}
func (c ProjectionCache) InvalidateViewer(ctx context.Context, viewer string) error {
	if c.Redis != nil {
		if err := c.Redis.Del(ctx, c.Namespace.Key("sidebar", nil, []string{viewer})).Err(); err != nil {
			return err
		}
		if err := c.deletePattern(ctx, c.Namespace.Pattern("unread", []string{viewer})); err != nil {
			return err
		}
		return c.deletePattern(ctx, c.Namespace.Pattern("firstpage", nil)+":"+socialwireredis.Digest(viewer))
	}
	for _, table := range []string{"sidebar_projection_cache", "unread_counts_cache", "first_page_cache"} {
		if _, err := c.DB.ExecContext(ctx, fmt.Sprintf("DELETE FROM %s WHERE viewer_did=$1", table), viewer); err != nil {
			return err
		}
	}
	return nil
}
func (c ProjectionCache) InvalidatePublication(ctx context.Context, publication string) error {
	if c.Redis != nil {
		return c.deletePattern(ctx, c.Namespace.Pattern("firstpage", []string{publication}))
	}
	_, err := c.DB.ExecContext(ctx, "DELETE FROM first_page_cache WHERE publication_id=$1", publication)
	return err
}
func (c ProjectionCache) InvalidateAll(ctx context.Context) error {
	if c.Redis != nil {
		for _, domain := range []string{"sidebar", "unread", "firstpage"} {
			if err := c.deletePattern(ctx, c.Namespace.Pattern(domain, nil)); err != nil {
				return err
			}
		}
		return nil
	}
	for _, table := range []string{"sidebar_projection_cache", "unread_counts_cache", "first_page_cache"} {
		if _, err := c.DB.ExecContext(ctx, fmt.Sprintf("DELETE FROM %s", table)); err != nil {
			return err
		}
	}
	return nil
}
