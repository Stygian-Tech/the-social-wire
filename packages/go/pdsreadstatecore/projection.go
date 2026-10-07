package pdsreadstatecore

import (
	"context"
	"database/sql"
	"encoding/json"

	r "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
)

func persistProjection(ctx context.Context, tx *sql.Tx, viewer string, operations []r.Operation) error {
	for _, table := range []string{"exact", "boundaries"} {
		if _, err := tx.ExecContext(ctx, `CREATE TEMP TABLE tsw_pds_`+table+`_stage (LIKE appview_pds_read_state_`+table+` INCLUDING ALL) ON COMMIT DROP`); err != nil {
			return err
		}
	}
	for start := 0; start < len(operations); start += 250 {
		batch, err := json.Marshal(operations[start:min(start+250, len(operations))])
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO tsw_pds_exact_stage AS target (viewer_did,subject_uri,sequence,is_read,acted_at)
SELECT DISTINCT ON (subject.uri) $1,subject.uri,(operation->>'sequence')::bigint,operation->>'state'='read',(operation->>'actedAt')::timestamptz
FROM jsonb_array_elements($2::jsonb) operation CROSS JOIN LATERAL jsonb_array_elements_text(operation->'subjectUris') subject(uri)
ORDER BY subject.uri,(operation->>'sequence')::bigint DESC ON CONFLICT(viewer_did,subject_uri) DO UPDATE SET sequence=EXCLUDED.sequence,is_read=EXCLUDED.is_read,acted_at=EXCLUDED.acted_at WHERE EXCLUDED.sequence>target.sequence`, viewer, string(batch)); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO tsw_pds_boundaries_stage (viewer_did,rule_key,sequence,is_read,acted_at,publication_id,author_did,scope_keys,boundary_at,boundary_uri)
SELECT DISTINCT $1,encode(sha256(convert_to(boundary.value::text,'UTF8')),'hex'),(item.operation->>'sequence')::bigint,item.operation->>'state'='read',(item.operation->>'actedAt')::timestamptz,
boundary.value#>>'{scope,publicationId}',boundary.value#>>'{scope,authorDid}',boundary.value#>'{scope,publicationSiteKeys}',(boundary.value->>'createdAt')::timestamptz,boundary.value->>'entryId'
FROM jsonb_array_elements($2::jsonb) item(operation) CROSS JOIN LATERAL jsonb_array_elements(item.operation->'boundaries') boundary(value)
ON CONFLICT(viewer_did,sequence,rule_key) DO NOTHING`, viewer, string(batch)); err != nil {
			return err
		}
	}
	statements := []string{
		`INSERT INTO appview_pds_read_state_exact AS target SELECT * FROM tsw_pds_exact_stage ON CONFLICT(viewer_did,subject_uri) DO UPDATE SET sequence=EXCLUDED.sequence,is_read=EXCLUDED.is_read,acted_at=EXCLUDED.acted_at WHERE (target.sequence,target.is_read,target.acted_at) IS DISTINCT FROM (EXCLUDED.sequence,EXCLUDED.is_read,EXCLUDED.acted_at)`,
		`INSERT INTO appview_pds_read_state_boundaries AS target SELECT * FROM tsw_pds_boundaries_stage ON CONFLICT(viewer_did,sequence,rule_key) DO UPDATE SET is_read=EXCLUDED.is_read,acted_at=EXCLUDED.acted_at WHERE (target.is_read,target.acted_at) IS DISTINCT FROM (EXCLUDED.is_read,EXCLUDED.acted_at)`,
		`DELETE FROM appview_pds_read_state_exact target WHERE viewer_did=$1 AND NOT EXISTS(SELECT 1 FROM tsw_pds_exact_stage incoming WHERE incoming.viewer_did=target.viewer_did AND incoming.subject_uri=target.subject_uri)`,
		`DELETE FROM appview_pds_read_state_boundaries target WHERE viewer_did=$1 AND NOT EXISTS(SELECT 1 FROM tsw_pds_boundaries_stage incoming WHERE incoming.viewer_did=target.viewer_did AND incoming.sequence=target.sequence AND incoming.rule_key=target.rule_key)`,
	}
	for index, statement := range statements {
		var err error
		if index < 2 {
			_, err = tx.ExecContext(ctx, statement)
		} else {
			_, err = tx.ExecContext(ctx, statement, viewer)
		}
		if err != nil {
			return err
		}
	}
	return nil
}
