package thinappviewcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"time"
)

type CounterStore struct {
	DB           *sql.DB
	PDSAuthority func(context.Context, string) (bool, error)
	PDSIsRead    func(context.Context, string, string) (bool, error)
}
type counterScope struct {
	viewer, publication string
	primary             *string
	scopes, sites, keys []string
}

func (s CounterStore) scopes(ctx context.Context, did, site string) ([]counterScope, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT viewer_did,publication_id,publication_at_uri,publication_scope_at_uris::text,publication_site_urls::text,scope_keys::text FROM appview_publication_scopes WHERE author_did=$1`, did)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	scopes := []counterScope{}
	for rows.Next() {
		var scope counterScope
		var uris, sites, keys string
		if err := rows.Scan(&scope.viewer, &scope.publication, &scope.primary, &uris, &sites, &keys); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(uris), &scope.scopes); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(sites), &scope.sites); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(keys), &scope.keys); err != nil {
			return nil, err
		}
		primary := ""
		if scope.primary != nil {
			primary = *scope.primary
		}
		if len(scope.keys) == 0 || MatchesPublication(site, primary, scope.scopes, scope.sites) {
			scopes = append(scopes, scope)
		}
	}
	return scopes, rows.Err()
}
func (s CounterStore) mark(ctx context.Context, scope counterScope, delta int, at time.Time) error {
	_, err := s.DB.ExecContext(ctx, `INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at)
 VALUES($1,$2,$3,$4,'estimated',true,$5) ON CONFLICT(viewer_did,publication_id) DO UPDATE SET unread_count=GREATEST(0,appview_unread_counters.unread_count+$3),generation=EXCLUDED.generation,accuracy='estimated',dirty=true,counted_at=EXCLUDED.counted_at`, scope.viewer, scope.publication, delta, int64(math.Round(float64(at.UnixNano())/1e6)), at)
	return err
}
func (s CounterStore) Dirty(ctx context.Context, did, site string, at time.Time) error {
	scopes, err := s.scopes(ctx, did, site)
	if err != nil {
		return err
	}
	for _, scope := range scopes {
		if err := s.mark(ctx, scope, 0, at); err != nil {
			return err
		}
	}
	return nil
}
func (s CounterStore) Increment(ctx context.Context, item IndexedContentItem, at time.Time) error {
	site := ""
	if item.PublicationSite != nil {
		site = *item.PublicationSite
	}
	scopes, err := s.scopes(ctx, item.AuthorDID, site)
	if err != nil {
		return err
	}
	for _, scope := range scopes {
		pds := false
		if s.PDSAuthority != nil {
			pds, err = s.PDSAuthority(ctx, scope.viewer)
			if err != nil {
				return err
			}
		}
		if pds {
			if s.PDSIsRead == nil {
				return errors.New("PDS read-state resolver unavailable")
			}
			read, err := s.PDSIsRead(ctx, scope.viewer, item.URI)
			if err != nil {
				return err
			}
			if read {
				continue
			}
		} else {
			var floor time.Time
			var floorURI *string
			err := s.DB.QueryRowContext(ctx, "SELECT read_floor_at,read_floor_uri FROM appview_publication_read_floors WHERE viewer_did=$1 AND publication_id=$2", scope.viewer, scope.publication).Scan(&floor, &floorURI)
			if err != nil && !errors.Is(err, sql.ErrNoRows) {
				return err
			}
			covered := err == nil && (item.CreatedAt.Before(floor) || item.CreatedAt.Equal(floor) && (floorURI == nil || item.URI <= *floorURI))
			var override, read bool
			if covered {
				if err := s.DB.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM appview_unread_overrides WHERE viewer_did=$1 AND subject_uri=$2)", scope.viewer, item.URI).Scan(&override); err != nil {
					return err
				}
				if !override {
					continue
				}
			}
			if err := s.DB.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM read_marks WHERE viewer_did=$1 AND subject_uri=$2)", scope.viewer, item.URI).Scan(&read); err != nil {
				return err
			}
			if read {
				continue
			}
		}
		if err := s.mark(ctx, scope, 1, at); err != nil {
			return err
		}
	}
	return nil
}
