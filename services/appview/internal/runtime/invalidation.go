package runtime

import (
	"context"
	"database/sql"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func (h *Host) invalidateRead(ctx context.Context, cache thinappviewcore.ProjectionCache, viewer, subject string) error {
	if subject == "" {
		return h.invalidateUnread(ctx, cache, viewer, "")
	}
	var publication sql.NullString
	err := h.DB.QueryRowContext(ctx, `SELECT publication_site FROM content_items WHERE uri=$1`, subject).Scan(&publication)
	if err == sql.ErrNoRows {
		return nil
	}
	if err != nil {
		return err
	}
	return h.invalidateUnread(ctx, cache, viewer, publication.String)
}
func (h *Host) invalidateUnread(ctx context.Context, cache thinappviewcore.ProjectionCache, viewer, publication string) error {
	if cache.Redis == nil {
		if publication == "" {
			_, e := h.DB.ExecContext(ctx, `DELETE FROM unread_counts_cache WHERE viewer_did=$1`, viewer)
			return e
		}
		_, e := h.DB.ExecContext(ctx, `DELETE FROM unread_counts_cache WHERE viewer_did=$1 AND publication_id=$2`, viewer, publication)
		return e
	}
	if publication != "" {
		return cache.Redis.Del(ctx, cache.Namespace.Key("unread", nil, []string{viewer, publication})).Err()
	}
	cursor := uint64(0)
	pattern := cache.Namespace.Pattern("unread", []string{viewer})
	for {
		keys, next, e := cache.Redis.Scan(ctx, cursor, pattern, 100).Result()
		if e != nil {
			return e
		}
		if len(keys) > 0 {
			if e := cache.Redis.Del(ctx, keys...).Err(); e != nil {
				return e
			}
		}
		cursor = next
		if cursor == 0 {
			return nil
		}
	}
}
