package pdsreadstatecore

import (
	"context"
	"database/sql"
	"reflect"
	"time"

	r "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
)

func verifyLegacyParity(ctx context.Context, tx *sql.Tx, viewer string, operations []r.Operation) error {
	var overlap bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM appview_publication_scopes a
 JOIN appview_publication_read_floors af ON af.viewer_did=a.viewer_did AND af.publication_id=a.publication_id
 JOIN appview_publication_scopes b ON b.viewer_did=a.viewer_did AND b.author_did=a.author_did AND b.publication_id<>a.publication_id
 LEFT JOIN appview_publication_read_floors bf ON bf.viewer_did=b.viewer_did AND bf.publication_id=b.publication_id
 WHERE a.viewer_did=$1 AND (a.scope_keys='[]'::jsonb OR b.scope_keys='[]'::jsonb OR a.scope_keys ?| ARRAY(SELECT jsonb_array_elements_text(b.scope_keys)))
 AND (af.read_floor_at,af.read_floor_uri) IS DISTINCT FROM (bf.read_floor_at,bf.read_floor_uri))`, viewer).Scan(&overlap); err != nil {
		return err
	}
	if overlap {
		return ErrLegacyScopeOverlap
	}
	var contradiction bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM read_marks r JOIN appview_unread_overrides u ON r.viewer_did=u.viewer_did AND r.subject_uri=u.subject_uri WHERE r.viewer_did=$1)`, viewer).Scan(&contradiction); err != nil {
		return err
	}
	if contradiction {
		return ErrParityMismatch
	}
	bySequence := map[int64][]r.Operation{}
	for _, operation := range operations {
		bySequence[operation.Sequence] = append(bySequence[operation.Sequence], operation)
	}
	var sequence int64
	position := exportPosition{Phase: -1}
	for {
		page, err := legacyPage(ctx, tx, viewer, position, 1000)
		if err != nil {
			return err
		}
		for _, row := range page.Rows {
			sequence++
			parts := bySequence[sequence]
			if len(parts) == 0 {
				return ErrParityMismatch
			}
			for _, part := range parts {
				acted, err := time.Parse(time.RFC3339Nano, part.ActedAt)
				if err != nil {
					return err
				}
				original, err := time.Parse(time.RFC3339Nano, row.ActedAt)
				if err != nil {
					return err
				}
				if !acted.Equal(original) || part.Calendar != nil {
					return ErrParityMismatch
				}
				if row.Boundary != nil {
					if part.State != r.Read || part.Selection != r.Boundaries || !reflect.DeepEqual(part.Boundaries, []r.Boundary{*row.Boundary}) {
						return ErrParityMismatch
					}
				} else {
					state := r.Read
					if row.Kind == "unread" {
						state = r.Unread
					}
					if row.SubjectURI == nil || part.State != state || part.Selection != r.Exact || !reflect.DeepEqual(part.SubjectURIs, []string{*row.SubjectURI}) {
						return ErrParityMismatch
					}
				}
			}
		}
		if page.Cursor == nil {
			return nil
		}
		position, err = decodeExportPosition(page.Cursor)
		if err != nil {
			return err
		}
	}
}
