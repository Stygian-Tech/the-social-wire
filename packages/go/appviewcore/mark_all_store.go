package appviewcore

import (
	"context"
	"database/sql"
	"sort"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

type MarkAllResult struct {
	Counters   []UnreadCounter
	Boundaries []ReadBoundary
}

func (s ReadMutationStore) MarkAll(ctx context.Context, viewer string, scopes []PublicationScope, at time.Time) (MarkAllResult, error) {
	result := MarkAllResult{Counters: []UnreadCounter{}, Boundaries: []ReadBoundary{}}
	unique := map[string]PublicationScope{}
	for _, scope := range scopes {
		if _, exists := unique[scope.PublicationID]; !exists {
			unique[scope.PublicationID] = scope
		}
	}
	ids := []string{}
	for id := range unique {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	if len(ids) == 0 {
		return result, nil
	}
	tx, err := beginLegacyMutation(ctx, s.DB, viewer)
	if err != nil {
		return result, err
	}
	defer tx.Rollback()
	generation := (at.UnixNano() + 500000) / 1000000
	for _, id := range ids {
		scope := unique[id]
		if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtext($1),hashtext($2))`, viewer, id); err != nil {
			return result, err
		}
		keys := PublicationSiteKeys(scope)
		scoped := scope.PublicationATURI != nil || len(scope.PublicationScopeATURIs) > 0 || len(scope.PublicationSiteURLs) > 0
		boundary := ReadBoundary{PublicationID: id, CreatedAt: at}
		if !scoped || len(keys) > 0 {
			var uri string
			var created time.Time
			err := tx.QueryRowContext(ctx, `SELECT uri,created_at FROM content_items WHERE author_did=$1 AND created_at<=$2 AND ($3::boolean=FALSE OR publication_site=ANY($4::text[])) ORDER BY created_at DESC,uri DESC LIMIT 1`, scope.AuthorDID, at, scoped, keys).Scan(&uri, &created)
			if err != nil && err != sql.ErrNoRows {
				return result, err
			}
			if err == nil {
				boundary.CreatedAt, boundary.EntryID = created, &uri
			}
		}
		var oldAt time.Time
		var oldURI sql.NullString
		err := tx.QueryRowContext(ctx, `SELECT read_floor_at,read_floor_uri FROM appview_publication_read_floors WHERE viewer_did=$1 AND publication_id=$2 FOR UPDATE`, viewer, id).Scan(&oldAt, &oldURI)
		if err != nil && err != sql.ErrNoRows {
			return result, err
		}
		if err == nil {
			old := ReadBoundary{PublicationID: id, CreatedAt: oldAt}
			if oldURI.Valid {
				old.EntryID = &oldURI.String
			}
			if !boundary.after(old) {
				boundary = old
			}
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO appview_publication_read_floors(viewer_did,publication_id,read_floor_at,read_floor_uri,generation,updated_at) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(viewer_did,publication_id) DO UPDATE SET read_floor_at=EXCLUDED.read_floor_at,read_floor_uri=EXCLUDED.read_floor_uri,generation=EXCLUDED.generation,updated_at=EXCLUDED.updated_at`, viewer, id, boundary.CreatedAt, boundary.EntryID, generation, at); err != nil {
			return result, err
		}
		rows, err := tx.QueryContext(ctx, `SELECT uo.subject_uri,ci.created_at,ci.publication_site FROM appview_unread_overrides uo JOIN content_items ci ON ci.uri=uo.subject_uri WHERE uo.viewer_did=$1 AND uo.created_at<=$2 AND ci.author_did=$3`, viewer, at, scope.AuthorDID)
		if err != nil {
			return result, err
		}
		covered := []string{}
		primary := ""
		if scope.PublicationATURI != nil {
			primary = *scope.PublicationATURI
		}
		for rows.Next() {
			var uri string
			var created time.Time
			var site sql.NullString
			if err := rows.Scan(&uri, &created, &site); err != nil {
				rows.Close()
				return result, err
			}
			if boundary.contains(created, uri) && thinappviewcore.MatchesPublication(site.String, primary, scope.PublicationScopeATURIs, scope.PublicationSiteURLs) {
				covered = append(covered, uri)
			}
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return result, err
		}
		if len(covered) > 0 {
			if _, err := tx.ExecContext(ctx, `DELETE FROM appview_unread_overrides WHERE viewer_did=$1 AND subject_uri=ANY($2::text[])`, viewer, covered); err != nil {
				return result, err
			}
		}
		count := 0
		if !scoped || len(keys) > 0 {
			if err := tx.QueryRowContext(ctx, markAllCountSQL, viewer, scope.AuthorDID, time.Now(), boundary.CreatedAt, boundary.EntryID != nil, boundary.EntryID, scoped, keys).Scan(&count); err != nil {
				return result, err
			}
		}
		counter := UnreadCounter{PublicationID: id, UnreadCount: count, Generation: generation, Accuracy: "exact", Dirty: false, CountedAt: at}
		if _, err := tx.ExecContext(ctx, `INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at) VALUES($1,$2,$3,$4,'exact',FALSE,$5) ON CONFLICT(viewer_did,publication_id) DO UPDATE SET unread_count=EXCLUDED.unread_count,generation=EXCLUDED.generation,accuracy=EXCLUDED.accuracy,dirty=FALSE,counted_at=EXCLUDED.counted_at`, viewer, id, count, generation, at); err != nil {
			return result, err
		}
		result.Counters = append(result.Counters, counter)
		result.Boundaries = append(result.Boundaries, boundary)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM appview_unread_overrides uo WHERE uo.viewer_did=$1 AND uo.created_at<=$2 AND NOT EXISTS(SELECT 1 FROM content_items ci WHERE ci.uri=uo.subject_uri)`, viewer, at); err != nil {
		return result, err
	}
	if err := tx.Commit(); err != nil {
		return result, err
	}
	return result, nil
}

const markAllCountSQL = `SELECT COUNT(*)::int FROM content_items ci
 LEFT JOIN read_marks rm ON rm.viewer_did=$1 AND rm.subject_uri=ci.uri
 LEFT JOIN appview_unread_overrides uo ON uo.viewer_did=$1 AND uo.subject_uri=ci.uri
 LEFT JOIN LATERAL appview_effective_entry_read_state($1,ci.uri,ci.author_did,ci.publication_site,ci.created_at,rm.subject_uri,uo.subject_uri) read_state ON TRUE
 WHERE ci.author_did=$2 AND ci.expires_at>$3
 AND (ci.created_at>$4 OR ($5::boolean AND ci.created_at=$4 AND ci.uri>$6::text) OR read_state.unread_uri IS NOT NULL)
 AND ($7::boolean=FALSE OR ci.publication_site=ANY($8::text[])) AND read_state.read_uri IS NULL`
