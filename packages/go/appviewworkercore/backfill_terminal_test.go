package appviewworkercore

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"strings"
	"testing"
	"time"
)

func TestBackfillTerminalAuditsIdempotencyAndLeavesDiagnosticGapUnverified(t *testing.T) {
	db := workerDatabase(t)
	nonce, err := newSnapshotToken()
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	at := time.Now().UTC()
	role := "terminal-" + nonce
	gap := nonce + "-gap"
	store := BackfillStore{DB: db, Environment: "dev", WorkerID: nonce, Authority: operationscore.RoleLeaseAuthority{Environment: "dev", Role: role, OwnerID: nonce, FencingToken: 1}}
	t.Cleanup(func() {
		db.Exec("DELETE FROM appview_recovery_failures WHERE job_id=$1", nonce)
		db.Exec("DELETE FROM operations_audit_events WHERE environment='dev'AND target_id=$1", nonce)
		db.Exec("DELETE FROM operations_idempotency_records WHERE environment='dev'AND target_id=$1", nonce)
		db.Exec("DELETE FROM appview_ingestion_gaps WHERE id=$1", gap)
		db.Exec("DELETE FROM appview_backfill_jobs WHERE id=$1", nonce)
		db.Exec("DELETE FROM operations_role_leases WHERE environment='dev'AND role=$1", role)
	})
	if _, err := db.Exec(`INSERT INTO operations_role_leases(environment,role,owner_id,fencing_token,acquired_at,lease_expires_at,updated_at)VALUES('dev',$1,$2,1,$3,$4,$3)`, role, nonce, at, at.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO appview_backfill_jobs(environment,id,source_mode,status,collections,author_dids,batch_size,rate_limit,max_concurrency,requested_by_did,audit_note,created_at,updated_at,lease_owner,lease_expires_at)VALUES('dev',$1,'pds_reconciliation','running','[]','[]',10,1,1,'did:plc:abcdefghijklmnopqrstuvwx','test',$2,$2,$1,$3)`, nonce, at, at.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO appview_ingestion_gaps(environment,id,source,reason,status,detected_at,updated_at,backfill_job_id)VALUES('dev',$1,'jetstream','fixture','backfilling',$2,$2,$3)`, gap, at, nonce); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE appview_backfill_jobs SET gap_id=$2 WHERE id=$1`, nonce, gap); err != nil {
		t.Fatal(err)
	}
	job := BackfillJob{ID: nonce, SourceMode: "pds_reconciliation"}
	if err := store.RecordFailure(ctx, job, strings.Repeat("a", 24), "site.standard.document", "pds_reconciliation", nil, "request_failed", at); err != nil {
		t.Fatal(err)
	}
	var failureCount int
	if err := db.QueryRow(`SELECT count(*)FROM appview_recovery_failures WHERE job_id=$1 AND record_identifier_hash=$2`, nonce, strings.Repeat("a", 24)).Scan(&failureCount); err != nil || failureCount != 1 {
		t.Fatalf("recovery failure %d %v", failureCount, err)
	}
	next, err := store.Terminal(ctx, job, "completed", nil, at)
	if err != nil {
		t.Fatal(err)
	}
	if next.Version != 1 {
		t.Fatal(next.Version)
	}
	replay, err := store.Terminal(ctx, job, "completed", nil, at)
	if err != nil || replay.Version != next.Version {
		t.Fatalf("replay %v %v", replay, err)
	}
	changed := "changed"
	if _, err := store.Terminal(ctx, job, "completed", &changed, at); !errors.Is(err, ErrBackfillIdempotency) {
		t.Fatalf("changed request accepted %v", err)
	}
	var status string
	if err := db.QueryRow(`SELECT status FROM appview_ingestion_gaps WHERE id=$1`, gap).Scan(&status); err != nil || status != "verification_required" {
		t.Fatalf("gap gained authority %s %v", status, err)
	}
	var payload string
	if err := db.QueryRow(`SELECT result_payload::text FROM operations_idempotency_records WHERE environment='dev'AND target_id=$1`, nonce).Scan(&payload); err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(payload), &result); err != nil {
		t.Fatal(err)
	}
	created, ok := result["createdAt"].(float64)
	if !ok || created < 700000000 || created > 1000000000 {
		t.Fatalf("Swift persisted date %v", result["createdAt"])
	}
	if result["status"] != "completed" || result["authorResults"] == nil {
		t.Fatal(result)
	}
	var audits int
	if err := db.QueryRow(`SELECT count(*) FROM operations_audit_events WHERE environment='dev'AND target_id=$1`, nonce).Scan(&audits); err != nil || audits != 2 {
		t.Fatalf("audits %d %v", audits, err)
	}
}
