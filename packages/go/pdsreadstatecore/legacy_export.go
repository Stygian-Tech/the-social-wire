package pdsreadstatecore

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"sort"
	"time"

	r "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
)

var ErrInvalidCursor = errors.New("invalid read-state export cursor")
var ErrRevisionChanged = errors.New("legacy read-state revision changed")
var ErrAlreadyMigrated = errors.New("read state already migrated")
var ErrLegacyScopeUnavailable = errors.New("legacy publication scope unavailable")
var ErrLegacyScopeOverlap = errors.New("legacy publication scopes overlap")
var ErrParityMismatch = errors.New("legacy read-state parity mismatch")

type LegacyRow struct {
	Kind       string      `json:"kind"`
	ActedAt    string      `json:"actedAt"`
	Boundary   *r.Boundary `json:"boundary,omitempty"`
	SubjectURI *string     `json:"subjectUri,omitempty"`
}

type ExportPage struct {
	LegacyRevision int64       `json:"legacyRevision"`
	Rows           []LegacyRow `json:"rows"`
	Cursor         *string     `json:"cursor,omitempty"`
}

type exportPosition struct {
	Phase int    `json:"phase"`
	Key   string `json:"key"`
}

func decodeExportPosition(cursor *string) (exportPosition, error) {
	if cursor == nil {
		return exportPosition{Phase: -1}, nil
	}
	data, err := base64.StdEncoding.DecodeString(*cursor)
	if err != nil {
		return exportPosition{}, ErrInvalidCursor
	}
	var object map[string]json.RawMessage
	if json.Unmarshal(data, &object) != nil || object["phase"] == nil || object["key"] == nil {
		return exportPosition{}, ErrInvalidCursor
	}
	var position exportPosition
	if json.Unmarshal(data, &position) != nil || position.Phase < 0 || position.Phase > 2 {
		return exportPosition{}, ErrInvalidCursor
	}
	return position, nil
}

func (s *Store) Export(ctx context.Context, viewer string, cursor *string, expected *int64, limit int) (ExportPage, error) {
	if cursor != nil && expected == nil {
		return ExportPage{}, ErrInvalidCursor
	}
	position, err := decodeExportPosition(cursor)
	if err != nil {
		return ExportPage{}, err
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return ExportPage{}, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `INSERT INTO appview_pds_read_state_authority(viewer_did) VALUES($1) ON CONFLICT DO NOTHING`, viewer); err != nil {
		return ExportPage{}, err
	}
	var revision int64
	var active bool
	if err := tx.QueryRowContext(ctx, `SELECT legacy_revision,manifest_cid IS NOT NULL FROM appview_pds_read_state_authority WHERE viewer_did=$1 FOR UPDATE`, viewer).Scan(&revision, &active); err != nil {
		return ExportPage{}, err
	}
	if active {
		return ExportPage{}, ErrAlreadyMigrated
	}
	if expected != nil && *expected != revision {
		return ExportPage{}, ErrRevisionChanged
	}
	page, err := legacyPage(ctx, tx, viewer, position, min(max(limit, 1), 1000))
	if err != nil {
		return ExportPage{}, err
	}
	page.LegacyRevision = revision
	if err := tx.Commit(); err != nil {
		return ExportPage{}, err
	}
	return page, nil
}

const legacyPageQuery = `SELECT phase,key,acted_at,boundary_at,boundary_uri,author_did,scope_keys::text FROM (
 SELECT 0 phase,floor.publication_id key,floor.updated_at acted_at,floor.read_floor_at boundary_at,floor.read_floor_uri boundary_uri,scope.author_did,scope.scope_keys
 FROM appview_publication_read_floors floor LEFT JOIN appview_publication_scopes scope ON scope.viewer_did=floor.viewer_did AND scope.publication_id=floor.publication_id WHERE floor.viewer_did=$1
 UNION ALL SELECT 1,subject_uri,created_at,NULL,NULL,NULL,NULL FROM appview_unread_overrides WHERE viewer_did=$1
 UNION ALL SELECT 2,subject_uri,created_at,NULL,NULL,NULL,NULL FROM read_marks WHERE viewer_did=$1) rows
 WHERE phase>$2 OR (phase=$2 AND key COLLATE "C">$3 COLLATE "C") ORDER BY phase,key COLLATE "C" LIMIT $4`

func legacyPage(ctx context.Context, tx *sql.Tx, viewer string, position exportPosition, limit int) (ExportPage, error) {
	rows, err := tx.QueryContext(ctx, legacyPageQuery, viewer, position.Phase, position.Key, limit+1)
	if err != nil {
		return ExportPage{}, err
	}
	defer rows.Close()
	page := ExportPage{Rows: []LegacyRow{}}
	var last exportPosition
	more := false
	for rows.Next() {
		if len(page.Rows) == limit {
			more = true
			break
		}
		var phase int
		var key string
		var acted time.Time
		var boundaryAt sql.NullTime
		var boundaryURI, author, keys sql.NullString
		if err := rows.Scan(&phase, &key, &acted, &boundaryAt, &boundaryURI, &author, &keys); err != nil {
			return ExportPage{}, err
		}
		row := LegacyRow{ActedAt: acted.UTC().Format("2006-01-02T15:04:05.000Z")}
		if phase == 0 {
			if !boundaryAt.Valid || !author.Valid || !keys.Valid {
				return ExportPage{}, ErrLegacyScopeUnavailable
			}
			var scopes []string
			if err := json.Unmarshal([]byte(keys.String), &scopes); err != nil {
				return ExportPage{}, err
			}
			sort.Strings(scopes)
			boundary := r.Boundary{Scope: r.Scope{PublicationID: key, AuthorDID: author.String, PublicationSiteKeys: scopes}, CreatedAt: boundaryAt.Time.UTC().Format("2006-01-02T15:04:05.000Z")}
			if boundaryURI.Valid {
				boundary.EntryID = &boundaryURI.String
			}
			row.Kind, row.Boundary = "boundary", &boundary
		} else {
			row.Kind = "read"
			if phase == 1 {
				row.Kind = "unread"
			}
			row.SubjectURI = &key
		}
		page.Rows = append(page.Rows, row)
		last = exportPosition{Phase: phase, Key: key}
	}
	if err := rows.Err(); err != nil {
		return ExportPage{}, err
	}
	if more {
		data, err := json.Marshal(last)
		if err != nil {
			return ExportPage{}, err
		}
		cursor := base64.StdEncoding.EncodeToString(data)
		page.Cursor = &cursor
	}
	return page, nil
}
