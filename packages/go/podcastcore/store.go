package podcastcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

type Store struct {
	DB      *sql.DB
	Private *PrivateStorage
}

func NewStore(db *sql.DB, privateKey string) *Store {
	storage, _ := NewPrivateStorage(privateKey)
	return &Store{DB: db, Private: storage}
}
func jsonValue(v any) (string, error) { data, err := json.Marshal(v); return string(data), err }
func publishedDate(raw string) time.Time {
	if strings.Contains(raw, ".") {
		return time.Unix(0, 0).UTC()
	}
	t, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return time.Unix(0, 0).UTC()
	}
	return t
}
func (s *Store) Alias(ctx context.Context, alias, canonical, kind string) error {
	_, err := s.DB.ExecContext(ctx, `INSERT INTO podcast_aliases(alias,canonical_id,entity_kind) VALUES($1,$2,$3) ON CONFLICT(alias) DO NOTHING`, alias, canonical, kind)
	return err
}
func (s *Store) Upsert(ctx context.Context, show Show, episodes []Episode) error {
	if show.Visibility != nil && *show.Visibility == "private" || IsPrivateID(show.ID) {
		return ErrInvalidRequest
	}
	for _, e := range episodes {
		if e.Visibility != nil && *e.Visibility == "private" || IsPrivateID(e.ID) {
			return ErrInvalidRequest
		}
	}
	data, err := jsonValue(show)
	if err != nil {
		return err
	}
	_, err = s.DB.ExecContext(ctx, `INSERT INTO podcast_shows(id,feed_url,source_kind,source_uri,show_json) VALUES($1,$2,$3,$4,$5::jsonb) ON CONFLICT(id) DO UPDATE SET show_json=EXCLUDED.show_json,source_uri=COALESCE(EXCLUDED.source_uri,podcast_shows.source_uri),updated_at=now()`, show.ID, show.FeedURL, show.SourceKind, show.SourceURI, data)
	if err != nil {
		return err
	}
	for _, e := range episodes {
		if e.Guid != nil {
			var canonical, raw string
			err := s.DB.QueryRowContext(ctx, `SELECT id,episode_json::text FROM podcast_episodes WHERE show_id=$1 AND guid=$2 LIMIT 1`, show.ID, e.Guid).Scan(&canonical, &raw)
			if err != nil && !errors.Is(err, sql.ErrNoRows) {
				return err
			}
			if err == nil {
				var old Episode
				if err := json.Unmarshal([]byte(raw), &old); err != nil {
					return err
				}
				if e.SourceURI == nil {
					e.SourceURI = old.SourceURI
				}
				if len(e.Chapters) == 0 && equalString(e.ChapterSourceURL, old.ChapterSourceURL) {
					e.Chapters = old.Chapters
				}
				if canonical != e.ID {
					if err := s.Alias(ctx, e.ID, canonical, "episode"); err != nil {
						return err
					}
					e.ID = canonical
				}
			}
		}
		data, err := jsonValue(e)
		if err != nil {
			return err
		}
		if _, err := s.DB.ExecContext(ctx, `INSERT INTO podcast_episodes(id,show_id,guid,episode_json,published_at) VALUES($1,$2,$3,$4::jsonb,$5) ON CONFLICT(id) DO UPDATE SET episode_json=EXCLUDED.episode_json,updated_at=now()`, e.ID, show.ID, e.Guid, data, publishedDate(e.PublishedAt)); err != nil {
			return err
		}
	}
	for _, alias := range []*string{show.FeedURL, show.SourceURI} {
		if alias != nil {
			if err := s.Alias(ctx, *alias, show.ID, "show"); err != nil {
				return err
			}
		}
	}
	if show.Guid != nil {
		return s.Alias(ctx, "guid:"+*show.Guid, show.ID, "show")
	}
	return nil
}
func equalString(a, b *string) bool { return a == nil && b == nil || a != nil && b != nil && *a == *b }
func (s *Store) Show(ctx context.Context, id string) (*Show, error) {
	return singleJSON[Show](ctx, s.DB, `SELECT show_json::text FROM podcast_shows WHERE id=$1 OR id=(SELECT canonical_id FROM podcast_aliases WHERE alias=$1 AND entity_kind='show') LIMIT 1`, id)
}
func (s *Store) Episode(ctx context.Context, id string) (*Episode, error) {
	return singleJSON[Episode](ctx, s.DB, `SELECT episode_json::text FROM podcast_episodes WHERE id=$1 OR id=(SELECT canonical_id FROM podcast_aliases WHERE alias=$1 AND entity_kind='episode') LIMIT 1`, id)
}
func (s *Store) Shows(ctx context.Context, viewer string) ([]Show, error) {
	return manyJSON[Show](ctx, s.DB, `SELECT s.show_json::text FROM podcast_shows s JOIN podcast_subscriptions v ON v.show_id=s.id WHERE v.viewer_did=$1 ORDER BY lower(s.show_json->>'title'),s.id`, viewer)
}
func (s *Store) Episodes(ctx context.Context, showID string, cursor *string, limit int) ([]Episode, error) {
	return manyJSON[Episode](ctx, s.DB, `SELECT episode_json::text FROM podcast_episodes WHERE show_id=$1 AND ($2::text IS NULL OR (published_at,id)<(SELECT published_at,id FROM podcast_episodes WHERE id=$2)) ORDER BY published_at DESC,id DESC LIMIT $3`, showID, cursor, max(1, min(limit, 100)))
}

type queryer interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func singleJSON[T any](ctx context.Context, db queryer, query string, args ...any) (*T, error) {
	var raw string
	if err := db.QueryRowContext(ctx, query, args...).Scan(&raw); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	var value T
	if err := json.Unmarshal([]byte(raw), &value); err != nil {
		return nil, err
	}
	return &value, nil
}
func manyJSON[T any](ctx context.Context, db queryer, query string, args ...any) ([]T, error) {
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []T{}
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		var value T
		if err := json.Unmarshal([]byte(raw), &value); err != nil {
			return nil, err
		}
		result = append(result, value)
	}
	return result, rows.Err()
}
func (s *Store) CanonicalEpisodeIDs(ctx context.Context, ids []string) (map[string]string, error) {
	result := map[string]string{}
	if len(ids) == 0 {
		return result, nil
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT alias,canonical_id FROM podcast_aliases WHERE alias=ANY($1) AND entity_kind='episode'`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var a, id string
		if err := rows.Scan(&a, &id); err != nil {
			return nil, err
		}
		result[a] = id
	}
	return result, rows.Err()
}
func (s *Store) ManualEpisodeAliases(ctx context.Context, links []ManualLink) (map[string]string, error) {
	result := map[string]string{}
	for _, link := range links {
		rows, err := s.DB.QueryContext(ctx, `SELECT native.id,rss.id FROM podcast_episodes native JOIN podcast_episodes rss ON rss.guid=native.guid WHERE native.show_id=$1 AND rss.show_id=$2 AND native.guid IS NOT NULL`, link.ProtocolShowID, link.RSSShowID)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var native, rss string
			if err := rows.Scan(&native, &rss); err != nil {
				rows.Close()
				return nil, err
			}
			result[native] = rss
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return nil, err
		}
	}
	return result, nil
}

type Subscription struct{ ShowID, URI string }

func (s *Store) Subscriptions(ctx context.Context, viewer string, records []Subscription) error {
	ids := make([]string, len(records))
	for i, r := range records {
		ids[i] = r.ShowID
	}
	if _, err := s.DB.ExecContext(ctx, `DELETE FROM podcast_subscriptions WHERE viewer_did=$1 AND NOT(show_id=ANY($2))`, viewer, ids); err != nil {
		return err
	}
	for _, r := range records {
		if _, err := s.DB.ExecContext(ctx, `INSERT INTO podcast_subscriptions(viewer_did,show_id,source_uri) VALUES($1,$2,$3) ON CONFLICT(viewer_did,show_id) DO UPDATE SET source_uri=EXCLUDED.source_uri,updated_at=now()`, viewer, r.ShowID, r.URI); err != nil {
			return err
		}
	}
	return nil
}
