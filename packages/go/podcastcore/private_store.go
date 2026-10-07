package podcastcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"
)

func (s *Store) requirePrivate() (*PrivateStorage, error) {
	if s.Private == nil {
		return nil, ErrPrivateStorageUnavailable
	}
	return s.Private, nil
}
func openJSON[T any](storage *PrivateStorage, raw, viewer, entity, id string) (*T, error) {
	plain, err := storage.Open(raw, viewer, entity, id)
	if err != nil {
		return nil, err
	}
	var value T
	if err := json.Unmarshal([]byte(plain), &value); err != nil {
		return nil, err
	}
	return &value, nil
}
func (s *Store) PrivateShow(ctx context.Context, viewer, id string) (*Show, error) {
	storage, err := s.requirePrivate()
	if err != nil {
		return nil, err
	}
	var raw string
	if err := s.DB.QueryRowContext(ctx, `SELECT show_data FROM podcast_private_shows WHERE viewer_did=$1 AND id=$2`, viewer, id).Scan(&raw); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return openJSON[Show](storage, raw, viewer, "show", id)
}
func (s *Store) PrivateEpisode(ctx context.Context, viewer, id string) (*Episode, error) {
	storage, err := s.requirePrivate()
	if err != nil {
		return nil, err
	}
	var raw string
	if err := s.DB.QueryRowContext(ctx, `SELECT episode_data FROM podcast_private_episodes WHERE viewer_did=$1 AND id=$2`, viewer, id).Scan(&raw); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return openJSON[Episode](storage, raw, viewer, "episode", id)
}
func (s *Store) PrivateShows(ctx context.Context, viewer string) ([]Show, error) {
	result := []Show{}
	if s.Private == nil {
		return result, nil
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT id,show_data FROM podcast_private_shows WHERE viewer_did=$1 ORDER BY id`, viewer)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id, raw string
		if err := rows.Scan(&id, &raw); err != nil {
			return nil, err
		}
		v, err := openJSON[Show](s.Private, raw, viewer, "show", id)
		if err != nil {
			return nil, err
		}
		result = append(result, *v)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.SliceStable(result, func(i, j int) bool { return strings.ToLower(result[i].Title) < strings.ToLower(result[j].Title) })
	return result, nil
}

type PrivateFeed struct {
	URL         string
	RefreshedAt time.Time
}

func (s *Store) PrivateFeed(ctx context.Context, viewer, id string) (*PrivateFeed, error) {
	storage, err := s.requirePrivate()
	if err != nil {
		return nil, err
	}
	var raw string
	var at time.Time
	if err := s.DB.QueryRowContext(ctx, `SELECT feed_data,updated_at FROM podcast_private_shows WHERE viewer_did=$1 AND id=$2`, viewer, id).Scan(&raw, &at); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	feed, err := storage.Open(raw, viewer, "feed", id)
	if err != nil {
		return nil, err
	}
	return &PrivateFeed{URL: feed, RefreshedAt: at}, nil
}
func (s *Store) StalePrivateFeeds(ctx context.Context, viewer string, limit int) ([]string, error) {
	result := []string{}
	if s.Private == nil {
		return result, nil
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT id,feed_data FROM podcast_private_shows WHERE viewer_did=$1 AND updated_at<now()-interval '15 minutes' ORDER BY updated_at,id LIMIT $2`, viewer, max(0, min(limit, 2)))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id, raw string
		if err := rows.Scan(&id, &raw); err != nil {
			return nil, err
		}
		feed, err := s.Private.Open(raw, viewer, "feed", id)
		if err != nil {
			return nil, err
		}
		result = append(result, feed)
	}
	return result, rows.Err()
}
func (s *Store) OwnsPrivateEpisodes(ctx context.Context, viewer string, ids []string) (bool, error) {
	if len(ids) == 0 {
		return true, nil
	}
	storage, err := s.requirePrivate()
	if err != nil {
		return false, err
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT id,episode_data FROM podcast_private_episodes WHERE viewer_did=$1 AND id=ANY($2)`, viewer, ids)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	found := map[string]bool{}
	for rows.Next() {
		var id, raw string
		if err := rows.Scan(&id, &raw); err != nil {
			return false, err
		}
		if _, err := openJSON[Episode](storage, raw, viewer, "episode", id); err != nil {
			return false, err
		}
		found[id] = true
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	for _, id := range ids {
		if !found[id] {
			return false, nil
		}
	}
	return true, nil
}
func (s *Store) SavePrivateCatalog(ctx context.Context, viewer, feedURL string, show Show, episodes []Episode, existingOnly bool) error {
	if !PrivateURLAllowed(feedURL) || show.Visibility == nil || *show.Visibility != "private" || !IsPrivateID(show.ID) {
		return ErrInvalidRequest
	}
	for _, e := range episodes {
		if e.ShowID != show.ID || e.Visibility == nil || *e.Visibility != "private" || !IsPrivateID(e.ID) {
			return ErrInvalidRequest
		}
	}
	storage, err := s.requirePrivate()
	if err != nil {
		return err
	}
	feedData, err := storage.Seal(feedURL, viewer, "feed", show.ID)
	if err != nil {
		return err
	}
	showJSON, err := jsonValue(show)
	if err != nil {
		return err
	}
	showData, err := storage.Seal(showJSON, viewer, "show", show.ID)
	if err != nil {
		return err
	}
	ids := make([]string, len(episodes))
	for i, e := range episodes {
		ids[i] = e.ID
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT id,episode_data FROM podcast_private_episodes WHERE viewer_did=$1 AND id=ANY($2)`, viewer, ids)
	if err != nil {
		return err
	}
	previous := map[string]Episode{}
	for rows.Next() {
		var id, raw string
		if err := rows.Scan(&id, &raw); err != nil {
			rows.Close()
			return err
		}
		e, err := openJSON[Episode](storage, raw, viewer, "episode", id)
		if err != nil {
			rows.Close()
			return err
		}
		previous[id] = *e
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	type entry struct {
		id, data string
		date     time.Time
	}
	entries := make([]entry, 0, len(episodes))
	for _, e := range episodes {
		if old, ok := previous[e.ID]; ok && len(e.Chapters) == 0 && equalString(e.ChapterSourceURL, old.ChapterSourceURL) {
			e.Chapters = old.Chapters
		}
		raw, err := jsonValue(e)
		if err != nil {
			return err
		}
		encrypted, err := storage.Seal(raw, viewer, "episode", e.ID)
		if err != nil {
			return err
		}
		entries = append(entries, entry{e.ID, encrypted, publishedDate(e.PublishedAt)})
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var existing string
	err = tx.QueryRowContext(ctx, `SELECT show_data FROM podcast_private_shows WHERE viewer_did=$1 AND id=$2 FOR UPDATE`, viewer, show.ID).Scan(&existing)
	if errors.Is(err, sql.ErrNoRows) {
		if existingOnly {
			return ErrNotFound
		}
	} else if err != nil {
		return err
	} else if _, err := storage.Open(existing, viewer, "show", show.ID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO podcast_private_shows(viewer_did,id,feed_hash,feed_data,show_data) VALUES($1,$2,$3,$4,$5) ON CONFLICT(viewer_did,id) DO UPDATE SET feed_data=EXCLUDED.feed_data,show_data=EXCLUDED.show_data,updated_at=now()`, viewer, show.ID, Identity(feedURL), feedData, showData); err != nil {
		return err
	}
	for _, e := range entries {
		if _, err := tx.ExecContext(ctx, `INSERT INTO podcast_private_episodes(viewer_did,id,show_id,episode_data,published_at) VALUES($1,$2,$3,$4,$5) ON CONFLICT(viewer_did,id) DO UPDATE SET episode_data=EXCLUDED.episode_data,published_at=EXCLUDED.published_at`, viewer, e.id, show.ID, e.data, e.date); err != nil {
			return err
		}
	}
	return tx.Commit()
}
func (s *Store) PrivateEpisodes(ctx context.Context, viewer, showID string, cursor *string, limit int) ([]Episode, error) {
	if _, err := s.requirePrivate(); err != nil {
		return nil, err
	}
	return s.catalogEpisodes(ctx, viewer, `SELECT id,episode_data,true FROM podcast_private_episodes WHERE viewer_did=$1 AND show_id=$2 AND ($3::text IS NULL OR (published_at,id)<(SELECT published_at,id FROM podcast_private_episodes WHERE viewer_did=$1 AND id=$3)) ORDER BY published_at DESC,id DESC LIMIT $4`, viewer, showID, cursor, max(1, min(limit, 100)))
}
func (s *Store) SubscribedEpisodes(ctx context.Context, viewer string, cursor *string, limit int) ([]Episode, error) {
	return s.catalogEpisodes(ctx, viewer, `WITH catalog AS (SELECT e.id,e.published_at,e.episode_json::text AS payload,false AS is_private FROM podcast_episodes e JOIN podcast_subscriptions s ON s.show_id=e.show_id WHERE s.viewer_did=$1 UNION ALL SELECT id,published_at,episode_data,true FROM podcast_private_episodes WHERE viewer_did=$1 AND $2) SELECT id,payload,is_private FROM catalog WHERE ($3::text IS NULL OR (published_at,id)<(SELECT published_at,id FROM catalog WHERE id=$3)) ORDER BY published_at DESC,id DESC LIMIT $4`, viewer, s.Private != nil, cursor, max(1, min(limit, 100)))
}
func (s *Store) QueuedEpisodes(ctx context.Context, viewer string) ([]Episode, error) {
	state, err := s.State(ctx, viewer)
	if err != nil {
		return nil, err
	}
	queue := state.State.Queue
	if len(queue) == 0 {
		return []Episode{}, nil
	}
	episodes, err := s.catalogEpisodes(ctx, viewer, `SELECT id,episode_json::text,false FROM podcast_episodes WHERE id=ANY($1) UNION ALL SELECT id,episode_data,true FROM podcast_private_episodes WHERE viewer_did=$2 AND id=ANY($1)`, queue, viewer)
	if err != nil {
		return nil, err
	}
	byID := map[string]Episode{}
	for _, e := range episodes {
		byID[e.ID] = e
	}
	result := []Episode{}
	for _, id := range queue {
		if e, ok := byID[id]; ok {
			result = append(result, e)
		}
	}
	return result, nil
}
func (s *Store) catalogEpisodes(ctx context.Context, viewer, query string, args ...any) ([]Episode, error) {
	rows, err := s.DB.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []Episode{}
	for rows.Next() {
		var id, raw string
		var private bool
		if err := rows.Scan(&id, &raw, &private); err != nil {
			return nil, err
		}
		if private {
			storage, err := s.requirePrivate()
			if err != nil {
				return nil, err
			}
			e, err := openJSON[Episode](storage, raw, viewer, "episode", id)
			if err != nil {
				return nil, err
			}
			result = append(result, *e)
		} else {
			var e Episode
			if err := json.Unmarshal([]byte(raw), &e); err != nil {
				return nil, err
			}
			result = append(result, e)
		}
	}
	return result, rows.Err()
}
func (s *Store) RemovePrivateSubscription(ctx context.Context, viewer, showID string) (bool, error) {
	show, err := s.PrivateShow(ctx, viewer, showID)
	if err != nil {
		return false, err
	}
	if show == nil {
		return false, nil
	}
	var id string
	err = s.DB.QueryRowContext(ctx, `WITH ids AS MATERIALIZED (SELECT id FROM podcast_private_episodes WHERE viewer_did=$1 AND show_id=$2), removed AS (DELETE FROM podcast_private_shows WHERE viewer_did=$1 AND id=$2 RETURNING id), state AS (UPDATE podcast_viewer_state SET revision=revision+1,updated_at=now(),state_json=state_json || jsonb_build_object('queue',COALESCE((SELECT jsonb_agg(value) FROM jsonb_array_elements_text(COALESCE(state_json->'queue','[]'::jsonb)) WHERE value NOT IN(SELECT id FROM ids)),'[]'::jsonb),'progress',COALESCE(state_json->'progress','{}'::jsonb)-ARRAY(SELECT id FROM ids),'subscriptions',COALESCE((SELECT jsonb_agg(value) FROM jsonb_array_elements_text(COALESCE(state_json->'subscriptions','[]'::jsonb)) WHERE value<>$2),'[]'::jsonb)) WHERE viewer_did=$1 AND EXISTS(SELECT id FROM removed)) SELECT id FROM removed`, viewer, showID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}
