package pdsreadstatecore

import (
	"context"
	"database/sql"
	"sort"
	"strconv"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
)

// PrepareBoundaries preserves monotonic legacy watermarks while selecting the
// latest indexed entry in each canonical publication scope, including expired
// historical rows as the Swift store does. Callers resolve scope keys first.
func (s Store) PrepareBoundaries(ctx context.Context, viewer string, scopes []readstatecore.Scope, at time.Time) ([]readstatecore.Boundary, error) {
	ordered := append([]readstatecore.Scope(nil), scopes...)
	sort.SliceStable(ordered, func(i, j int) bool { return ordered[i].PublicationID < ordered[j].PublicationID })
	result := make([]readstatecore.Boundary, 0, len(ordered))
	for _, scope := range ordered {
		keys := append([]string{}, scope.PublicationSiteKeys...)
		sort.Strings(keys)
		scope.PublicationSiteKeys = keys
		boundaryAt := at
		var boundaryURI *string
		var uri string
		var created time.Time
		err := s.DB.QueryRowContext(ctx, `SELECT uri,created_at FROM content_items WHERE author_did=$1 AND created_at<=$2 AND ($3::boolean OR publication_site=ANY($4::text[])) ORDER BY created_at DESC,uri DESC LIMIT 1`, scope.AuthorDID, at, len(keys) == 0, keys).Scan(&uri, &created)
		if err != nil && err != sql.ErrNoRows {
			return nil, err
		}
		if err == nil {
			boundaryAt, boundaryURI = created, &uri
		}
		var priorAt time.Time
		var priorURI sql.NullString
		err = s.DB.QueryRowContext(ctx, `SELECT read_floor_at,read_floor_uri FROM appview_publication_read_floors WHERE viewer_did=$1 AND publication_id=$2`, viewer, scope.PublicationID).Scan(&priorAt, &priorURI)
		if err != nil && err != sql.ErrNoRows {
			return nil, err
		}
		if err == nil && (boundaryAt.Before(priorAt) || boundaryAt.Equal(priorAt) && (!priorURI.Valid || boundaryURI != nil && *boundaryURI <= priorURI.String)) {
			boundaryAt = priorAt
			boundaryURI = nil
			if priorURI.Valid {
				value := priorURI.String
				boundaryURI = &value
			}
		}
		result = append(result, readstatecore.Boundary{Scope: scope, CreatedAt: boundaryAt.UTC().Format("2006-01-02T15:04:05.000Z"), EntryID: boundaryURI})
	}
	return result, nil
}

// PreviewBoundaries evaluates only cached subject IDs against a verified local
// selection; it does not mutate read state or substitute a publication badge.
func (s Store) PreviewBoundaries(ctx context.Context, boundaries []readstatecore.Boundary, subjects []string) ([]string, error) {
	if len(boundaries) > 1000 || len(subjects) > 1000 {
		return nil, readstatecore.ErrSizeLimit
	}
	result := []string{}
	if len(boundaries) == 0 || len(subjects) == 0 {
		return result, nil
	}
	operations := make([]readstatecore.Operation, len(boundaries))
	for i, boundary := range boundaries {
		operations[i] = readstatecore.Operation{ActionID: "preview-" + strconv.Itoa(i), Sequence: int64(i + 1), State: readstatecore.Read, Selection: readstatecore.Boundaries, ActedAt: boundary.CreatedAt, Boundaries: []readstatecore.Boundary{boundary}}
	}
	projection, err := readstatecore.NewProjection(operations, int64(len(operations)), 1)
	if err != nil {
		return nil, err
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT uri,author_did,publication_site,created_at FROM content_items WHERE uri=ANY($1::text[]) ORDER BY uri COLLATE "C"`, subjects)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var subject readstatecore.Subject
		if err := rows.Scan(&subject.URI, &subject.AuthorDID, &subject.PublicationSite, &subject.CreatedAt); err != nil {
			return nil, err
		}
		if projection.Resolve(subject).IsRead {
			result = append(result, subject.URI)
		}
	}
	return result, rows.Err()
}
