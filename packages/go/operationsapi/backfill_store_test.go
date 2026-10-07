package operationsapi

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5/pgxpool"
	"os"
	"testing"
	"time"
)

func TestBackfillTransitionsPreserveLinkedGapVerificationAndPauseVersion(t *testing.T) {
	url := os.Getenv("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	store, err := NewPostgresStore(pool, "dev")
	if err != nil {
		t.Fatal(err)
	}
	fixture := func(jobStatus, gapStatus, mode string) (string, string) {
		t.Helper()
		jobID, err := randomUUID()
		if err != nil {
			t.Fatal(err)
		}
		gapID, err := randomUUID()
		if err != nil {
			t.Fatal(err)
		}
		_, err = pool.Exec(ctx, `INSERT INTO appview_ingestion_gaps(environment,id,source,reason,status,collections,detected_at,updated_at,version) VALUES('dev',$1,'fixture','fixture',$2,'["site.standard.document"]'::jsonb,now(),now(),0)`, gapID, gapStatus)
		if err != nil {
			t.Fatal(err)
		}
		_, err = pool.Exec(ctx, `INSERT INTO appview_backfill_jobs(environment,id,gap_id,source_mode,status,collections,author_dids,batch_size,rate_limit,max_concurrency,estimated_count,requested_by_did,created_at,updated_at,version,verification_status,scope_truncated,validation_watermark) VALUES('dev',$1,$2,$3,$4,'["site.standard.document"]'::jsonb,'["did:plc:abcdefghijklmnopqrstuvwx"]'::jsonb,100,100,1,100,'did:plc:fixture',now(),now(),0,'verified',false,'fixture-validation')`, jobID, gapID, mode, jobStatus)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = pool.Exec(ctx, `UPDATE appview_ingestion_gaps SET backfill_job_id=$2 WHERE environment='dev' AND id=$1`, gapID, jobID); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			for _, table := range []string{"operations_audit_events", "operations_idempotency_records"} {
				_, _ = pool.Exec(c, `DELETE FROM `+table+` WHERE environment='dev' AND (target_id=$1 OR target_id=$2)`, jobID, gapID)
			}
			_, _ = pool.Exec(c, `UPDATE appview_ingestion_gaps SET backfill_job_id=NULL WHERE environment='dev' AND id=$1`, gapID)
			_, _ = pool.Exec(c, `DELETE FROM appview_backfill_jobs WHERE environment='dev' AND id=$1`, jobID)
			_, _ = pool.Exec(c, `DELETE FROM appview_ingestion_gaps WHERE environment='dev' AND id=$1`, gapID)
		})
		return jobID, gapID
	}
	jobID, gapID := fixture("queued", "backfill_queued", "pds_reconciliation")
	cancelled, err := store.TransitionBackfill(ctx, jobID, "cancelled", 0, "did:plc:fixture", "cancel-"+jobID, nil, nil, nil, time.Now())
	if err != nil || cancelled.Status != "cancelled" || cancelled.Version != 1 {
		t.Fatal(cancelled, err)
	}
	gap, err := store.FetchGap(ctx, gapID)
	if err != nil || gap.Status != "confirmed" || gap.Version != 1 {
		t.Fatal("cancel did not release linked gap", gap, err)
	}
	attention, err := store.ListBackfills(ctx, "attention", 250, nil)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, job := range attention.Items {
		found = found || job.ID == jobID
	}
	if !found {
		t.Fatal("cancelled job missing from attention")
	}
	history, err := store.ListBackfills(ctx, "history", 250, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, job := range history.Items {
		if job.ID == jobID {
			t.Fatal("cancelled job incorrectly counted as completed history")
		}
	}
	jobID, gapID = fixture("running", "backfilling", "pds_reconciliation")
	paused, err := store.TransitionBackfill(ctx, jobID, "paused", 0, "did:plc:fixture", "pause-"+jobID, nil, nil, nil, time.Now())
	if err != nil || paused.Version != 1 || paused.LeaseOwner != nil {
		t.Fatal(paused, err)
	}
	if _, err = store.TransitionBackfill(ctx, jobID, "queued", 0, "did:plc:fixture", "stale-resume-"+jobID, nil, nil, nil, time.Now()); !errors.Is(err, ErrVersionConflict) {
		t.Fatal("stale resume accepted", err)
	}
	resumed, err := store.TransitionBackfill(ctx, jobID, "queued", 1, "did:plc:fixture", "resume-"+jobID, nil, nil, nil, time.Now())
	if err != nil || resumed.Version != 2 {
		t.Fatal(resumed, err)
	}
	gap, err = store.FetchGap(ctx, gapID)
	if err != nil || gap.Status != "backfilling" {
		t.Fatal("pause/resume rewrote linked gap", gap, err)
	}
	jobID, gapID = fixture("running", "backfilling", "pds_reconciliation")
	completed, err := store.TransitionBackfill(ctx, jobID, "completed", 0, "did:plc:fixture", "complete-"+jobID, nil, nil, nil, time.Now())
	if err != nil || completed.Status != "completed" {
		t.Fatal(completed, err)
	}
	gap, err = store.FetchGap(ctx, gapID)
	if err != nil || gap.Status != "verification_required" {
		t.Fatal("diagnostic recovery falsely resolved gap", gap, err)
	}
	jobID, _ = fixture("running", "backfilling", "pds_reconciliation")
	if _, err = store.TransitionBackfill(ctx, jobID, "completed", 0, "system:worker", "worker-complete-"+jobID, nil, nil, nil, time.Now()); !errors.Is(err, ErrLeaseConflict) {
		t.Fatal("worker terminal transition bypassed lease", err)
	}
}
