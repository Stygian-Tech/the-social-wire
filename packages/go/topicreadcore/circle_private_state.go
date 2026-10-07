package topicreadcore

import (
	"context"
	"database/sql"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"strings"
	"time"
)

type CirclePrivateState struct {
	DB     *sql.DB
	Hasher *wirecore.ActorHasher
	Cache  *CircleCache
}

func (s *CirclePrivateState) LoadGraph(ctx context.Context, viewer string, excluded map[string]bool, now time.Time) (*CircleGraph, error) {
	if s.Cache == nil {
		return nil, nil
	}
	return s.Cache.LoadGraph(ctx, viewer, excluded, now)
}
func (s *CirclePrivateState) StoreGraph(ctx context.Context, g CircleGraph, excluded map[string]bool, now time.Time) error {
	if s.Cache == nil {
		return nil
	}
	return s.Cache.StoreGraph(ctx, g, excluded, now)
}
func (s *CirclePrivateState) Hidden(ctx context.Context, viewer string) (map[string]bool, error) {
	hash, err := s.Hasher.Hash(viewer)
	if err != nil {
		return nil, err
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT canonical_key FROM appview_circle_hidden_items WHERE viewer_key_hash=$1`, hash)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := map[string]bool{}
	for rows.Next() {
		var key string
		if err = rows.Scan(&key); err != nil {
			return nil, err
		}
		result[key] = true
	}
	return result, rows.Err()
}
func (s *CirclePrivateState) SetHidden(ctx context.Context, viewer, id string, hidden bool, now time.Time) (string, error) {
	id = strings.TrimSpace(id)
	if id == "" || len(id) > 128 {
		return "", ErrInvalidCursor
	}
	hash, err := s.Hasher.Hash(viewer)
	if err != nil {
		return "", err
	}
	if hidden {
		_, err = s.DB.ExecContext(ctx, `INSERT INTO appview_circle_hidden_items(viewer_key_hash,canonical_key,hidden_at)VALUES($1,$2,$3) ON CONFLICT(viewer_key_hash,canonical_key)DO UPDATE SET hidden_at=EXCLUDED.hidden_at`, hash, id, now)
	} else {
		_, err = s.DB.ExecContext(ctx, `DELETE FROM appview_circle_hidden_items WHERE viewer_key_hash=$1 AND canonical_key=$2`, hash, id)
	}
	if err == nil && s.Cache != nil {
		s.Cache.InvalidateEditions(ctx, viewer)
	}
	return id, err
}
func (s *CirclePrivateState) Purge(ctx context.Context, viewer string) error {
	if s.Cache != nil {
		if err := s.Cache.Purge(ctx, viewer); err != nil {
			return err
		}
	}
	hash, err := s.Hasher.Hash(viewer)
	if err != nil {
		return err
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, table := range []string{"appview_circle_edition_cache", "appview_circle_hidden_items", "appview_circle_graph_snapshots"} {
		if _, err = tx.ExecContext(ctx, `DELETE FROM `+table+` WHERE viewer_key_hash=$1`, hash); err != nil {
			return err
		}
	}
	return tx.Commit()
}
