package publicationcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"math"
	"sort"
	"time"
)

type CounterStore struct{ DB *sql.DB }

func counterGeneration(at time.Time) int64 { return int64(math.Round(float64(at.UnixNano()) / 1e6)) }
func (s CounterStore) Snapshot(ctx context.Context, viewer string, scopes []appviewcore.PublicationScope, at time.Time) (CounterSnapshot, error) {
	snapshot := CounterSnapshot{Counts: map[string]int{}, Accuracy: "exact", CountedAt: at, MissingPublicationIDs: []string{}}
	ids := []string{}
	seen := map[string]bool{}
	for _, scope := range scopes {
		if !seen[scope.PublicationID] {
			ids = append(ids, scope.PublicationID)
			seen[scope.PublicationID] = true
		}
	}
	if len(ids) == 0 {
		snapshot.Generation = counterGeneration(at)
		return snapshot, nil
	}
	rows, e := s.DB.QueryContext(ctx, `SELECT publication_id,unread_count,generation,accuracy,dirty,counted_at FROM appview_unread_counters WHERE viewer_did=$1 AND publication_id=ANY($2::text[])`, viewer, ids)
	if e != nil {
		return snapshot, e
	}
	defer rows.Close()
	found := map[string]bool{}
	snapshot.CountedAt = time.Time{}
	for rows.Next() {
		var id, accuracy string
		var count int
		var generation int64
		var dirty bool
		var countedAt time.Time
		if e = rows.Scan(&id, &count, &generation, &accuracy, &dirty, &countedAt); e != nil {
			return snapshot, e
		}
		found[id] = true
		snapshot.Counts[id] = count
		snapshot.Generation = max(snapshot.Generation, generation)
		if countedAt.After(snapshot.CountedAt) {
			snapshot.CountedAt = countedAt
		}
		snapshot.Dirty = snapshot.Dirty || dirty
		if accuracy != "exact" || dirty {
			snapshot.Accuracy = "estimated"
		}
	}
	if e = rows.Err(); e != nil {
		return snapshot, e
	}
	for _, id := range ids {
		if !found[id] {
			snapshot.Counts[id] = 0
			snapshot.MissingPublicationIDs = append(snapshot.MissingPublicationIDs, id)
			snapshot.Dirty = true
			snapshot.Accuracy = "estimated"
		}
	}
	sort.Strings(snapshot.MissingPublicationIDs)
	if snapshot.Generation == 0 {
		snapshot.Generation = counterGeneration(at)
	}
	if snapshot.CountedAt.IsZero() {
		snapshot.CountedAt = at
	}
	return snapshot, nil
}
func (s CounterStore) Refresh(ctx context.Context, viewer string, scopes []appviewcore.PublicationScope, at time.Time) (CounterSnapshot, error) {
	if len(scopes) == 0 {
		return s.Snapshot(ctx, viewer, scopes, at)
	}
	authors := []string{}
	ids := []string{}
	known := map[string]bool{}
	unique := map[string]appviewcore.PublicationScope{}
	for _, scope := range scopes {
		unique[scope.PublicationID] = scope
		if !known[scope.AuthorDID] {
			authors = append(authors, scope.AuthorDID)
			known[scope.AuthorDID] = true
		}
		ids = append(ids, scope.PublicationID)
	}
	rows, e := s.DB.QueryContext(ctx, `SELECT ci.author_did,ci.publication_site,COUNT(*)::int FROM content_items ci LEFT JOIN read_marks rm ON rm.viewer_did=$1 AND rm.subject_uri=ci.uri LEFT JOIN appview_unread_overrides uo ON uo.viewer_did=$1 AND uo.subject_uri=ci.uri LEFT JOIN LATERAL appview_effective_entry_read_state($1,ci.uri,ci.author_did,ci.publication_site,ci.created_at,rm.subject_uri,uo.subject_uri) read_state ON TRUE WHERE ci.author_did=ANY($2::text[]) AND ci.expires_at>$3 AND read_state.read_uri IS NULL GROUP BY ci.author_did,ci.publication_site`, viewer, authors, at)
	if e != nil {
		return CounterSnapshot{}, e
	}
	type countRow struct {
		author, site string
		count        int
	}
	countsBySite := []countRow{}
	for rows.Next() {
		var r countRow
		var site sql.NullString
		if e = rows.Scan(&r.author, &site, &r.count); e != nil {
			rows.Close()
			return CounterSnapshot{}, e
		}
		r.site = site.String
		countsBySite = append(countsBySite, r)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return CounterSnapshot{}, e
	}
	floors, e := s.DB.QueryContext(ctx, `SELECT publication_id,read_floor_at,read_floor_uri FROM appview_publication_read_floors WHERE viewer_did=$1 AND publication_id=ANY($2::text[])`, viewer, ids)
	if e != nil {
		return CounterSnapshot{}, e
	}
	type boundary struct {
		at  time.Time
		uri sql.NullString
	}
	boundaries := map[string]boundary{}
	for floors.Next() {
		var id string
		var b boundary
		if e = floors.Scan(&id, &b.at, &b.uri); e != nil {
			floors.Close()
			return CounterSnapshot{}, e
		}
		boundaries[id] = b
	}
	e = floors.Err()
	floors.Close()
	if e != nil {
		return CounterSnapshot{}, e
	}
	counters := []map[string]any{}
	for id, scope := range unique {
		count := 0
		publication := ""
		if scope.PublicationATURI != nil {
			publication = *scope.PublicationATURI
		}
		for _, r := range countsBySite {
			if r.author == scope.AuthorDID && thinappviewcore.MatchesPublication(r.site, publication, scope.PublicationScopeATURIs, scope.PublicationSiteURLs) {
				count += r.count
			}
		}
		if floor, has := boundaries[id]; has {
			var all int
			keys := appviewcore.PublicationSiteKeys(scope)
			scoped := scope.PublicationATURI != nil || len(scope.PublicationScopeATURIs) > 0 || len(scope.PublicationSiteURLs) > 0
			e = s.DB.QueryRowContext(ctx, `SELECT COUNT(*)::int FROM content_items ci LEFT JOIN read_marks rm ON rm.viewer_did=$1 AND rm.subject_uri=ci.uri LEFT JOIN appview_unread_overrides uo ON uo.viewer_did=$1 AND uo.subject_uri=ci.uri LEFT JOIN LATERAL appview_effective_entry_read_state($1,ci.uri,ci.author_did,ci.publication_site,ci.created_at,rm.subject_uri,uo.subject_uri) read_state ON TRUE WHERE ci.author_did=$2 AND ci.expires_at>$3 AND (ci.created_at>$4 OR ($5::boolean AND ci.created_at=$4 AND ci.uri>$6) OR read_state.unread_uri IS NOT NULL) AND ($7::boolean=FALSE OR ci.publication_site=ANY($8::text[])) AND read_state.read_uri IS NULL`, viewer, scope.AuthorDID, at, floor.at, floor.uri.Valid, floor.uri.String, scoped, keys).Scan(&all)
			if e != nil {
				return CounterSnapshot{}, e
			}
			count = all
		}
		counters = append(counters, map[string]any{"publication_id": id, "unread_count": count})
	}
	raw, _ := json.Marshal(counters)
	_, e = s.DB.ExecContext(ctx, `INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at) SELECT $1,x.publication_id,x.unread_count,$3,'exact',FALSE,$4 FROM jsonb_to_recordset($2::jsonb)AS x(publication_id text,unread_count int) ON CONFLICT(viewer_did,publication_id)DO UPDATE SET unread_count=EXCLUDED.unread_count,generation=EXCLUDED.generation,accuracy=EXCLUDED.accuracy,dirty=EXCLUDED.dirty,counted_at=EXCLUDED.counted_at`, viewer, string(raw), counterGeneration(at), at)
	if e != nil {
		return CounterSnapshot{}, e
	}
	return s.Snapshot(ctx, viewer, scopes, at)
}
