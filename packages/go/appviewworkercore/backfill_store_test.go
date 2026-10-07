package appviewworkercore

import (
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"testing"
	"time"
)

func TestBackfillVersionAndCoordinatorFences(t *testing.T) {
	db := workerDatabase(t)
	nonce, err := newSnapshotToken()
	if err != nil {
		t.Fatal(err)
	}
	at := time.Now()
	authority := operationscore.RoleLeaseAuthority{Environment: "dev", Role: "go-backfill-" + nonce, OwnerID: nonce, FencingToken: 1}
	store := BackfillStore{DB: db, Environment: "dev", WorkerID: nonce, Authority: authority}
	t.Cleanup(func() {
		db.Exec("DELETE FROM appview_backfill_jobs WHERE id=$1", nonce)
		db.Exec("DELETE FROM operations_role_leases WHERE environment='dev' AND role=$1", authority.Role)
	})
	_, err = db.Exec(`INSERT INTO operations_role_leases(environment,role,owner_id,fencing_token,acquired_at,lease_expires_at,updated_at)VALUES('dev',$1,$2,1,$3,$4,$3)`, authority.Role, nonce, at, at.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`INSERT INTO appview_backfill_jobs(environment,id,source_mode,status,collections,author_dids,batch_size,rate_limit,max_concurrency,requested_by_did,audit_note,created_at,updated_at)VALUES('dev',$1,'pds_reconciliation','queued','["site.standard.document"]','["did:plc:abcdefghijklmnopqrstuvwx"]',10,1,1,'did:plc:abcdefghijklmnopqrstuvwx','test',$2,$2)`, nonce, at)
	if err != nil {
		t.Fatal(err)
	}
	job, err := store.Claim(context.Background(), at)
	if err != nil {
		t.Fatal(err)
	}
	if job == nil || job.ID != nonce {
		t.Fatalf("claim %+v", job)
	}
	old := *job
	job.Processed = 1
	job.Reconciled = 1
	next, err := store.Checkpoint(context.Background(), *job, at.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	next, err = store.AuthorResults(context.Background(), next, []BackfillAuthorResult{{DID: "did:plc:abcdefghijklmnopqrstuvwx", Collection: "site.standard.document", DiscoveredCount: 1, ProcessedCount: 1, Status: "succeeded"}}, at.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	next, err = store.DiagnosticVerification(context.Background(), next, false, at.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	var verification, reason string
	if err := db.QueryRow(`SELECT verification_status,verification_reason FROM appview_backfill_jobs WHERE id=$1`, nonce).Scan(&verification, &reason); err != nil {
		t.Fatal(err)
	}
	if verification != "required" || reason != "scope_not_exact" {
		t.Fatalf("diagnostic gained authority %s %s", verification, reason)
	}
	if next.Version <= old.Version {
		t.Fatal("version did not advance")
	}
	if _, err := store.Checkpoint(context.Background(), old, at.Add(time.Second)); !errors.Is(err, ErrBackfillLease) {
		t.Fatalf("stale worker accepted %v", err)
	}
	if _, err := db.Exec(`UPDATE appview_backfill_jobs SET status='paused',version=version+1 WHERE id=$1`, nonce); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Checkpoint(context.Background(), next, at.Add(time.Second)); !errors.Is(err, ErrBackfillLease) {
		t.Fatalf("operator pause overwritten %v", err)
	}
	if _, err := db.Exec(`UPDATE operations_role_leases SET owner_id='replacement',fencing_token=2 WHERE environment='dev' AND role=$1`, authority.Role); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Claim(context.Background(), at); err == nil {
		t.Fatal("stale coordinator accepted")
	}
}
