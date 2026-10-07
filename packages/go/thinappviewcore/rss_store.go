package thinappviewcore

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

type RSSFetchMetadata struct {
	FeedURL                  string
	ETag, LastModified       *string
	LastPollAt, BackoffUntil *time.Time
	ConsecutiveErrors        int
}
type RSSStore struct{ DB *sql.DB }

func (s RSSStore) Metadata(ctx context.Context, feed string) (*RSSFetchMetadata, error) {
	metadata := &RSSFetchMetadata{FeedURL: feed}
	err := s.DB.QueryRowContext(ctx, `SELECT etag,last_modified,last_poll_at,backoff_until,consecutive_error_count FROM rss_feed_fetch_metadata WHERE feed_url=$1`, feed).Scan(&metadata.ETag, &metadata.LastModified, &metadata.LastPollAt, &metadata.BackoffUntil, &metadata.ConsecutiveErrors)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return metadata, nil
}
func (s RSSStore) StoreMetadata(ctx context.Context, m RSSFetchMetadata) error {
	_, err := s.DB.ExecContext(ctx, `INSERT INTO rss_feed_fetch_metadata(feed_url,etag,last_modified,last_poll_at,backoff_until,consecutive_error_count)VALUES($1,$2,$3,$4,$5,$6)
 ON CONFLICT(feed_url)DO UPDATE SET etag=EXCLUDED.etag,last_modified=EXCLUDED.last_modified,last_poll_at=EXCLUDED.last_poll_at,backoff_until=EXCLUDED.backoff_until,consecutive_error_count=EXCLUDED.consecutive_error_count`, m.FeedURL, m.ETag, m.LastModified, m.LastPollAt, m.BackoffUntil, m.ConsecutiveErrors)
	return err
}
func (s RSSStore) ListFeeds(ctx context.Context, limit int) ([]string, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT publication_site FROM content_items WHERE author_did=$1 AND publication_site IS NOT NULL AND expires_at>$2 GROUP BY publication_site ORDER BY MIN(indexed_at) ASC LIMIT $3`, RSSAuthorDID, time.Now(), max(1, min(limit, 200)))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	feeds := []string{}
	for rows.Next() {
		var feed string
		if err := rows.Scan(&feed); err != nil {
			return nil, err
		}
		feeds = append(feeds, feed)
	}
	return feeds, rows.Err()
}
