package appviewcore

import (
	"context"
	"sort"
	"time"
)

func (s ReadMutationStore) PutMany(ctx context.Context, viewer string, subjects []string, at time.Time) error {
	if len(subjects) == 0 {
		return nil
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
		return err
	}
	defer tx.Rollback()
	for start := 0; start < len(ordered); start += 500 {
		batch := ordered[start:min(start+500, len(ordered))]
		if _, err := tx.ExecContext(ctx, `INSERT INTO read_marks(viewer_did,subject_uri,created_at) SELECT $1,subject_uri,$3::timestamptz FROM unnest($2::text[]) subjects(subject_uri) ON CONFLICT(viewer_did,subject_uri) DO UPDATE SET created_at=EXCLUDED.created_at`, viewer, batch, at); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM appview_unread_overrides WHERE viewer_did=$1 AND subject_uri=ANY($2::text[])`, viewer, batch); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at)
 SELECT DISTINCT scope.viewer_did,scope.publication_id,0,$3::bigint,'estimated',TRUE,$4::timestamptz
 FROM appview_publication_scopes scope JOIN content_items ci ON ci.author_did=scope.author_did
 AND (jsonb_array_length(scope.scope_keys)=0 OR (ci.publication_site IS NOT NULL AND scope.scope_keys ? ci.publication_site))
 WHERE scope.viewer_did=$1 AND ci.uri=ANY($2::text[])
 ON CONFLICT(viewer_did,publication_id) DO UPDATE SET generation=EXCLUDED.generation,accuracy=EXCLUDED.accuracy,dirty=TRUE,counted_at=EXCLUDED.counted_at`, viewer, batch, (at.UnixNano()+500000)/1000000, at); err != nil {
			return err
		}
	}
	return tx.Commit()
}
