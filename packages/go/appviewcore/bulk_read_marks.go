package appviewcore

import (
	"context"
	"sort"
	"time"
)

// PutMany applies a frozen read action without replacing later explicit unread
// intent. The returned subjects are the only IDs the caller may confirm as read.
func (s ReadMutationStore) PutMany(ctx context.Context, viewer string, subjects []string, at time.Time) ([]string, error) {
	applied := []string{}
	if len(subjects) == 0 {
		return applied, nil
	}
	set := map[string]bool{}
	for _, subject := range subjects {
		set[subject] = true
	}
	ordered := make([]string, 0, len(set))
	for subject := range set {
		ordered = append(ordered, subject)
	}
	sort.Strings(ordered)
	tx, err := beginLegacyMutation(ctx, s.DB, viewer)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	for start := 0; start < len(ordered); start += 500 {
		batch := ordered[start:min(start+500, len(ordered))]
		// The authority-row lock also serializes Put, so its committed override
		// cannot change between this check and the writes below.
		rows, err := tx.QueryContext(ctx, `SELECT subject_uri FROM unnest($2::text[]) WITH ORDINALITY subjects(subject_uri,position)
 WHERE NOT EXISTS(SELECT 1 FROM appview_unread_overrides unread
 WHERE unread.viewer_did=$1 AND unread.subject_uri=subjects.subject_uri AND unread.created_at>$3::timestamptz)
 ORDER BY position`, viewer, batch, at)
		if err != nil {
			return nil, err
		}
		eligible := []string{}
		for rows.Next() {
			var subject string
			if err := rows.Scan(&subject); err != nil {
				rows.Close()
				return nil, err
			}
			eligible = append(eligible, subject)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return nil, err
		}
		if len(eligible) == 0 {
			continue
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO read_marks(viewer_did,subject_uri,created_at) SELECT $1,subject_uri,$3::timestamptz FROM unnest($2::text[]) subjects(subject_uri) ON CONFLICT(viewer_did,subject_uri) DO UPDATE SET created_at=GREATEST(read_marks.created_at,EXCLUDED.created_at)`, viewer, eligible, at); err != nil {
			return nil, err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM appview_unread_overrides WHERE viewer_did=$1 AND subject_uri=ANY($2::text[]) AND created_at<=$3::timestamptz`, viewer, eligible, at); err != nil {
			return nil, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at)
 SELECT DISTINCT scope.viewer_did,scope.publication_id,0,$3::bigint,'estimated',TRUE,$4::timestamptz
 FROM appview_publication_scopes scope JOIN content_items ci ON ci.author_did=scope.author_did
 AND (jsonb_array_length(scope.scope_keys)=0 OR (ci.publication_site IS NOT NULL AND scope.scope_keys ? ci.publication_site))
 WHERE scope.viewer_did=$1 AND ci.uri=ANY($2::text[])
 ON CONFLICT(viewer_did,publication_id) DO UPDATE SET generation=GREATEST(appview_unread_counters.generation,EXCLUDED.generation),accuracy=EXCLUDED.accuracy,dirty=TRUE,counted_at=GREATEST(appview_unread_counters.counted_at,EXCLUDED.counted_at)`, viewer, eligible, (at.UnixNano()+500000)/1000000, at); err != nil {
			return nil, err
		}
		applied = append(applied, eligible...)
	}
	if len(applied) > 0 {
		if _, err := tx.ExecContext(ctx, `DELETE FROM unread_counts_cache WHERE viewer_did=$1`, viewer); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return applied, nil
}
