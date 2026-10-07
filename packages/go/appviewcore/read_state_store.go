package appviewcore

import (
	"context"
	"database/sql"
	"time"
)

type ReadStateStore struct{ DB *sql.DB }

// ReadStates resolves authority, explicit state and legacy floors in one statement
// snapshot, including authoritative PDS false values and explicit unread overrides.
func (s ReadStateStore) ReadStates(ctx context.Context, viewer string, entries []Entry) (map[string]bool, error) {
	states := make(map[string]bool, len(entries))
	if len(entries) == 0 {
		return states, nil
	}
	ids, publications := []string{}, []string{}
	for _, entry := range entries {
		ids = append(ids, entry.EntryID)
		if entry.PublicationID != nil {
			publications = append(publications, *entry.PublicationID)
		}
	}
	rows, err := s.DB.QueryContext(ctx, `WITH authority AS MATERIALIZED (
 SELECT COALESCE((SELECT manifest_cid IS NOT NULL FROM appview_pds_read_state_authority WHERE viewer_did=$1),FALSE) is_pds)
 SELECT subject.uri,CASE WHEN authority.is_pds THEN 'pds' ELSE 'legacy' END,
 CASE WHEN authority.is_pds THEN COALESCE(appview_pds_entry_is_read($1,subject.uri,ci.author_did,ci.publication_site,ci.created_at),FALSE)
 ELSE rm.subject_uri IS NOT NULL END,uo.subject_uri IS NOT NULL,NULL::timestamptz,NULL::text
 FROM unnest($2::text[]) subject(uri) CROSS JOIN authority
 LEFT JOIN content_items ci ON authority.is_pds AND ci.uri=subject.uri
 LEFT JOIN read_marks rm ON NOT authority.is_pds AND rm.viewer_did=$1 AND rm.subject_uri=subject.uri
 LEFT JOIN appview_unread_overrides uo ON NOT authority.is_pds AND uo.viewer_did=$1 AND uo.subject_uri=subject.uri
 UNION ALL SELECT floor.publication_id,'floor',FALSE,FALSE,floor.read_floor_at,floor.read_floor_uri
 FROM authority JOIN appview_publication_read_floors floor ON NOT authority.is_pds AND floor.viewer_did=$1 AND floor.publication_id=ANY($3::text[])`, viewer, ids, publications)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	pds, explicit, unread := map[string]bool{}, map[string]bool{}, map[string]bool{}
	floors := map[string]readFloor{}
	for rows.Next() {
		var key, kind string
		var read, override bool
		var at sql.NullTime
		var uri sql.NullString
		if err := rows.Scan(&key, &kind, &read, &override, &at, &uri); err != nil {
			return nil, err
		}
		switch kind {
		case "pds":
			pds[key] = read
		case "floor":
			if at.Valid {
				floors[key] = readFloor{At: at.Time, URI: uri}
			}
		default:
			explicit[key] = read
			unread[key] = override
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if value, ok := pds[entry.EntryID]; ok {
			states[entry.EntryID] = value
			continue
		}
		covered := false
		if entry.PublicationID != nil {
			if floor, ok := floors[*entry.PublicationID]; ok {
				covered = floor.contains(entry.FeedPositionAt, entry.EntryID)
			}
		}
		states[entry.EntryID] = explicit[entry.EntryID] || covered && !unread[entry.EntryID]
	}
	return states, nil
}

func (s ReadStateStore) PDSAuthority(ctx context.Context, viewer string) (bool, error) {
	var pds bool
	err := s.DB.QueryRowContext(ctx, `SELECT COALESCE((SELECT manifest_cid IS NOT NULL FROM appview_pds_read_state_authority WHERE viewer_did=$1),FALSE)`, viewer).Scan(&pds)
	return pds, err
}

type readFloor struct {
	At  time.Time
	URI sql.NullString
}

func (f readFloor) contains(at time.Time, uri string) bool {
	return at.Before(f.At) || at.Equal(f.At) && (!f.URI.Valid || uri <= f.URI.String)
}
