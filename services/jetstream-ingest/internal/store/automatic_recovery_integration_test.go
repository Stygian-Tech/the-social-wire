package store

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func automaticFixture(t *testing.T) (context.Context, *Postgres, Lease) {
	t.Helper()
	databaseURL := os.Getenv("JETSTREAM_INGEST_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("JETSTREAM_INGEST_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(8)
	t.Cleanup(func() { _ = db.Close() })
	id, err := newIncidentID()
	if err != nil {
		t.Fatal(err)
	}
	source := wireTestSource()
	source.Environment = "automatic-" + id
	source.Generation = "canonical-parent"
	p := New(db, source)
	p.ConfigureWireCompactIngest(true)
	p.ConfigureWireAdmission(100000, 1<<40)
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		for _, table := range []string{"ingestion_recovery_jobs", "ingestion_poison_records", "ingestion_recovery_controllers", "wire_ingestion_inbox", "wire_ingestion_recovery_anchors", "appview_ingestion_replay_usage", "appview_jetstream_checkpoints", "appview_ingestion_leases", "wire_ingestion_admission"} {
			if _, err := db.ExecContext(cleanup, "DELETE FROM "+table+" WHERE environment=$1", source.Environment); err != nil {
				t.Errorf("cleanup %s: %v", table, err)
			}
		}
	})
	if _, err := db.ExecContext(ctx, "INSERT INTO wire_ingestion_admission(environment,retained_rows) VALUES($1,0)", source.Environment); err != nil {
		t.Fatal(err)
	}
	lease, err := p.AcquireLease(ctx, "parent-controller", "fixture", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	return ctx, p, lease
}

func automaticEvent(seq uint64) ingest.InboxEvent {
	return ingest.InboxEvent{Seq: seq, Time: time.Now().UTC(), Kind: "account", RepoDID: "did:plc:automatic", Payload: []byte(`{"account":{"active":true}}`)}
}
func stageAutomaticFixture(t *testing.T, ctx context.Context, p *Postgres, lease Lease, seq uint64, state string) {
	t.Helper()
	event := automaticEvent(seq)
	if err := p.StageBatch(ctx, lease, []ingest.InboxEvent{event}, seq, event.Time, ReplayProgress{State: state}); err != nil {
		t.Fatal(err)
	}
}

func TestAutomaticRecoverySeamRestartFencingAndCanonicalInboxIntegration(t *testing.T) {
	ctx, p, lease := automaticFixture(t)
	stageAutomaticFixture(t, ctx, p, lease, 100, "replaying")
	checkpoint, err := p.LoadCheckpoint(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := p.StartAutomaticRecovery(ctx, lease, checkpoint, nil, nil); err != nil {
		t.Fatal(err)
	}
	// A durable gap obligation and the first fresh batch commit atomically.
	stageAutomaticFixture(t, ctx, p, lease, 200, "live")
	stageAutomaticFixture(t, ctx, p, lease, 210, "live")
	var jobs int
	if err := p.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM ingestion_recovery_jobs WHERE environment=$1", p.source.Environment).Scan(&jobs); err != nil || jobs != 1 {
		t.Fatalf("jobs=%d err=%v", jobs, err)
	}
	// Multiple claimers under one parent cannot claim the same job twice.
	var group sync.WaitGroup
	claimed := make(chan *RecoveryJob, 6)
	failures := make(chan error, 6)
	for range 6 {
		group.Add(1)
		go func() {
			defer group.Done()
			job, err := p.ClaimRecoveryJob(ctx, lease, 10000)
			if err != nil {
				failures <- err
			} else if job != nil {
				claimed <- job
			}
		}()
	}
	group.Wait()
	close(claimed)
	close(failures)
	for err := range failures {
		t.Fatal(err)
	}
	var job *RecoveryJob
	for next := range claimed {
		if job != nil {
			t.Fatal("duplicate concurrent claim")
		}
		job = next
	}
	if job == nil || job.AfterSeq != 99 || job.BeforeSeq != 200 {
		t.Fatalf("wrong seam: %#v", job)
	}
	archive := p.ForRecoveryJob(*job)
	stageAutomaticFixture(t, ctx, archive, lease, 150, "replaying")
	oldProgress := time.Now().Add(-time.Hour).UTC().Truncate(time.Microsecond)
	if _, err := p.db.ExecContext(ctx, "UPDATE ingestion_recovery_jobs SET last_progress_at=$2 WHERE environment=$1", p.source.Environment, oldProgress); err != nil {
		t.Fatal(err)
	}
	stageAutomaticFixture(t, ctx, archive, lease, 150, "replaying")
	var retainedProgress time.Time
	if err := p.db.QueryRowContext(ctx, "SELECT last_progress_at FROM ingestion_recovery_jobs WHERE environment=$1", p.source.Environment).Scan(&retainedProgress); err != nil || !retainedProgress.Equal(oldProgress) {
		t.Fatalf("duplicate boundary invented progress: %s %v", retainedProgress, err)
	}
	if err := archive.RecordReplayBytes(ctx, 1234); err != nil {
		t.Fatal(err)
	}
	// Historical data is visible to already-configured canonical workers, while
	// the live checkpoint remains at 210 rather than regressing to archive 150.
	var generation string
	if err := p.db.QueryRowContext(ctx, "SELECT source_generation FROM wire_ingestion_inbox WHERE environment=$1 AND seq=150", p.source.Environment).Scan(&generation); err != nil || generation != p.source.Generation {
		t.Fatalf("worker-invisible generation %q err=%v", generation, err)
	}
	checkpoint, err = p.LoadCheckpoint(ctx)
	if err != nil || !cursorEquals(checkpoint.LastStagedSeq, 210) {
		t.Fatalf("live checkpoint changed %#v %v", checkpoint, err)
	}
	stale := lease
	stale.FencingToken--
	event := automaticEvent(160)
	if err := archive.StageBatch(ctx, stale, []ingest.InboxEvent{event}, 160, event.Time, ReplayProgress{}); !errors.Is(err, ErrLeaseUnavailable) {
		t.Fatalf("stale recovery fence accepted: %v", err)
	}
	// Restart retains budget authority and exact bounds, taking over only under
	// a new parent fencing token; it does not mint a new child generation.
	if err := p.ReleaseLease(ctx, lease); err != nil {
		t.Fatal(err)
	}
	replacement, err := p.AcquireLease(ctx, lease.Name, "replacement", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	restarted := New(p.db, p.source)
	restarted.ConfigureWireCompactIngest(true)
	restarted.ConfigureWireAdmission(100000, 1<<40)
	state, err := restarted.StartAutomaticRecovery(ctx, replacement, checkpoint, nil, nil)
	if err != nil || state.IncidentBytes != 1234 {
		t.Fatalf("restart budget state %#v %v", state, err)
	}
	next, err := restarted.ClaimRecoveryJob(ctx, replacement, 10000)
	if err != nil || next == nil || next.ID != job.ID || !cursorEquals(next.LastStagedSeq, 150) {
		t.Fatalf("restart changed range/checkpoint %#v %v", next, err)
	}
	resumed := restarted.ForRecoveryJob(*next)
	for _, seq := range []uint64{99, 201} {
		outside := automaticEvent(seq)
		if err := resumed.StageBatch(ctx, replacement, []ingest.InboxEvent{outside}, seq, outside.Time, ReplayProgress{}); err == nil {
			t.Fatalf("archive admitted seq %d outside immutable range", seq)
		}
	}
	if err := resumed.CompleteRecoveryJob(ctx, replacement, 99, 201, ReplayProgress{SealedSeq: 201}); err == nil {
		t.Fatal("changed range accepted")
	}
	if err := resumed.CompleteRecoveryJob(ctx, replacement, 99, 200, ReplayProgress{SealedSeq: 199}); err == nil {
		t.Fatal("unsealed upper bound completed")
	}
	if err := resumed.CompleteRecoveryJob(ctx, replacement, 99, 200, ReplayProgress{SealedSeq: 200}); err != nil {
		t.Fatal(err)
	}
	if _, err := p.db.ExecContext(ctx, "UPDATE ingestion_recovery_jobs SET before_seq=201 WHERE environment=$1", p.source.Environment); err == nil {
		t.Fatal("database allowed immutable bound mutation")
	}
	if _, err := p.db.ExecContext(ctx, "UPDATE ingestion_recovery_jobs SET status='pending' WHERE environment=$1", p.source.Environment); err == nil {
		t.Fatal("database reopened completed coverage")
	}
}

func TestAutomaticRecoveryPoisonRollbackRetentionAndReplayIntegration(t *testing.T) {
	ctx, p, lease := automaticFixture(t)
	if _, err := p.StartAutomaticRecovery(ctx, lease, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	good := automaticEvent(10)
	poison := automaticEvent(11)
	cid := "original-cid"
	poison.RecordCID = &cid
	poison.Payload = []byte(`{"commit":{"record":{"same\u0000key":1,"same\ufffdkey":2}}}`)
	original := bytes.Clone(poison.Payload)
	following := automaticEvent(12)
	if err := p.StageBatch(ctx, lease, []ingest.InboxEvent{good, poison, following}, 12, following.Time, ReplayProgress{State: "live"}); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(original, poison.Payload) {
		t.Fatal("caller payload changed")
	}
	var raw []byte
	var storedCID, status string
	if err := p.db.QueryRowContext(ctx, "SELECT raw_payload,record_cid,status FROM ingestion_poison_records WHERE environment=$1 AND seq=11", p.source.Environment).Scan(&raw, &storedCID, &status); err != nil || !bytes.Equal(raw, original) || storedCID != cid || status != "quarantined" {
		t.Fatalf("poison evidence changed raw=%q cid=%q status=%q err=%v", raw, storedCID, status, err)
	}
	var count int
	if err := p.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM wire_ingestion_inbox WHERE environment=$1", p.source.Environment).Scan(&count); err != nil || count != 2 {
		t.Fatalf("good rows=%d err=%v", count, err)
	}
	// Replaying identical poison remains idempotent.
	if err := p.StageBatch(ctx, lease, []ingest.InboxEvent{poison}, 12, following.Time, ReplayProgress{State: "live"}); err != nil {
		t.Fatal(err)
	}
	// Same source sequence with different raw bytes must never overwrite evidence
	// or commit surrounding valid records/checkpoints.
	poison.Payload = []byte(`{"record":`)
	good.Seq = 13
	err := p.StageBatch(ctx, lease, []ingest.InboxEvent{good, poison}, 13, following.Time, ReplayProgress{State: "live"})
	if !errors.Is(err, ErrSourceDiscontinuity) {
		t.Fatalf("identity collision accepted: %v", err)
	}
	checkpoint, err := p.LoadCheckpoint(ctx)
	if err != nil || !cursorEquals(checkpoint.LastStagedSeq, 12) {
		t.Fatalf("failed quarantine advanced checkpoint %#v %v", checkpoint, err)
	}
	if err := p.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM wire_ingestion_inbox WHERE environment=$1", p.source.Environment).Scan(&count); err != nil || count != 2 {
		t.Fatalf("failed quarantine committed row count=%d err=%v", count, err)
	}
	if _, err := p.db.ExecContext(ctx, "UPDATE ingestion_poison_records SET expires_at=NOW()-interval '1 second' WHERE environment=$1", p.source.Environment); err != nil {
		t.Fatal(err)
	}
	if err := p.PrunePoisonPayloads(ctx); err != nil {
		t.Fatal(err)
	}
	if err := p.db.QueryRowContext(ctx, "SELECT raw_payload,status FROM ingestion_poison_records WHERE environment=$1", p.source.Environment).Scan(&raw, &status); err != nil || raw != nil || status != "expired" {
		t.Fatalf("raw evidence retention failed raw=%q status=%q err=%v", raw, status, err)
	}
}

func TestAutomaticRecoverySeamRollbackExpiryAndDiscontinuityIntegration(t *testing.T) {
	ctx, p, lease := automaticFixture(t)
	stageAutomaticFixture(t, ctx, p, lease, 100, "replaying")
	checkpoint, err := p.LoadCheckpoint(ctx)
	if err != nil {
		t.Fatal(err)
	}
	expiry := time.Now().Add(-time.Second)
	if _, err := p.StartAutomaticRecovery(ctx, lease, checkpoint, nil, &expiry); err != nil {
		t.Fatal(err)
	}
	// Invalid event time fails the inbox insert after gap registration. Neither
	// obligation nor live cursor may leak out of the rolled-back transaction.
	bad := automaticEvent(200)
	bad.RepoDID = "\x00"
	if err := p.StageBatch(ctx, lease, []ingest.InboxEvent{bad}, 200, bad.Time, ReplayProgress{State: "live"}); err == nil {
		t.Fatal("expected SQL text rejection")
	}
	var jobs int
	if err := p.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM ingestion_recovery_jobs WHERE environment=$1", p.source.Environment).Scan(&jobs); err != nil || jobs != 0 {
		t.Fatalf("failed stage leaked gap: %d %v", jobs, err)
	}
	state, err := p.AutomaticRecoveryState(ctx)
	if err != nil || !cursorEquals(state.LastLiveSeq, 100) || !cursorEquals(state.GapAfterSeq, 100) {
		t.Fatalf("failed stage advanced seam %#v %v", state, err)
	}
	stageAutomaticFixture(t, ctx, p, lease, 200, "live")
	if job, err := p.ClaimRecoveryJob(ctx, lease, 1000); err != nil || job != nil {
		t.Fatalf("expired recovery opened archive: %#v %v", job, err)
	}
	// Expired archive does not stop live staging or change the original expiry.
	stageAutomaticFixture(t, ctx, p, lease, 210, "live")
	if err := p.BlockSourceDiscontinuity(ctx, lease, "FutureCursor: source epoch reset"); err != nil {
		t.Fatal(err)
	}
	next := automaticEvent(220)
	if err := p.StageBatch(ctx, lease, []ingest.InboxEvent{next}, 220, next.Time, ReplayProgress{State: "live"}); !errors.Is(err, ErrSourceDiscontinuity) {
		t.Fatalf("blocked source admitted records: %v", err)
	}
	checkpoint, err = p.LoadCheckpoint(ctx)
	if err != nil || !cursorEquals(checkpoint.LastStagedSeq, 210) {
		t.Fatalf("discontinuity replaced old source cursor %#v %v", checkpoint, err)
	}
}

func TestAutomaticRecoveryCarriesSequentialBudgetAndDeadlineIntegration(t *testing.T) {
	ctx, p, lease := automaticFixture(t)
	stageAutomaticFixture(t, ctx, p, lease, 100, "replaying")
	checkpoint, err := p.LoadCheckpoint(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := p.RecordReplayBytes(ctx, 500); err != nil {
		t.Fatal(err)
	}
	event := automaticEvent(110)
	if err := p.StageBatch(ctx, lease, []ingest.InboxEvent{event}, 110, event.Time, ReplayProgress{State: "replaying", BytesDownloaded: 700}); err != nil {
		t.Fatal(err)
	}
	checkpoint, err = p.LoadCheckpoint(ctx)
	if err != nil {
		t.Fatal(err)
	}
	expiry := time.Now().Add(time.Hour)
	state, err := p.StartAutomaticRecovery(ctx, lease, checkpoint, nil, &expiry)
	if err != nil || state.IncidentBytes != 700 || !cursorEquals(state.LastLiveSeq, 110) || !cursorEquals(state.GapAfterSeq, 110) {
		t.Fatalf("sequential transition replenished authority %#v %v", state, err)
	}
	stageAutomaticFixture(t, ctx, p, lease, 200, "live")
	if job, err := p.ClaimRecoveryJob(ctx, lease, 700); err != nil || job != nil {
		t.Fatalf("incident allowance reset: %#v %v", job, err)
	}
	nextExpiry := expiry.Add(time.Hour)
	checkpoint, err = p.LoadCheckpoint(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := p.StartAutomaticRecovery(ctx, lease, checkpoint, nil, &nextExpiry); err != nil {
		t.Fatal(err)
	}
	var retained time.Time
	if err := p.db.QueryRowContext(ctx, "SELECT canary_expires_at FROM ingestion_recovery_controllers WHERE environment=$1", p.source.Environment).Scan(&retained); err != nil || retained.Sub(expiry).Abs() > time.Microsecond {
		t.Fatal(fmt.Sprintf("restart extended deadline: %s %v", retained, err))
	}
}

func TestAutomaticPoisonCapacityAllowsExactReplayButRejectsNewEvidenceIntegration(t *testing.T) {
	ctx, p, lease := automaticFixture(t)
	if _, err := p.StartAutomaticRecovery(ctx, lease, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	poison := automaticEvent(11)
	poison.Payload = []byte(`{"record":`)
	if err := p.StageBatch(ctx, lease, []ingest.InboxEvent{poison}, 11, poison.Time, ReplayProgress{State: "live"}); err != nil {
		t.Fatal(err)
	}
	if _, err := p.db.ExecContext(ctx, `INSERT INTO ingestion_poison_records(environment,source_generation,seq,source_host,repo_did,payload_sha256,reason) SELECT $1,$2,n,$3,'did:plc:capacity','fixture','fixture' FROM generate_series(20000,29998)n`, p.source.Environment, p.source.Generation, p.source.Host); err != nil {
		t.Fatal(err)
	}
	if _, err := p.db.ExecContext(ctx, `UPDATE ingestion_poison_records SET raw_payload=convert_to(repeat('x',$3::int),'UTF8') WHERE environment=$1 AND source_generation=$2 AND seq=20000`, p.source.Environment, p.source.Generation, poisonMaxPayloadBytes-len(poison.Payload)); err != nil {
		t.Fatal(err)
	}
	// At both limits, replaying an exact source identity adds no new evidence.
	if err := p.StageBatch(ctx, lease, []ingest.InboxEvent{poison, poison}, 11, poison.Time, ReplayProgress{State: "live"}); err != nil {
		t.Fatalf("idempotent overlap consumed quarantine capacity: %v", err)
	}
	poison.Seq = 12
	if err := p.StageBatch(ctx, lease, []ingest.InboxEvent{poison}, 12, poison.Time, ReplayProgress{State: "live"}); !errors.Is(err, ErrPoisonCapacityExceeded) {
		t.Fatalf("unbounded evidence admitted: %v", err)
	}
	checkpoint, err := p.LoadCheckpoint(ctx)
	if err != nil || !cursorEquals(checkpoint.LastStagedSeq, 11) {
		t.Fatalf("capacity failure advanced checkpoint: %#v %v", checkpoint, err)
	}
}
