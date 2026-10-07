package appviewworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

type repeatingSnapshotHTTP struct {
	did             string
	listCalls       int
	invalidDocument bool
}

func (g *repeatingSnapshotHTTP) Get(_ context.Context, raw string, _ http.Header, _ int, _ int) (int, http.Header, []byte, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return 0, nil, nil, err
	}
	if strings.HasSuffix(u.Path, "/did.json") {
		return 200, nil, []byte(fmt.Sprintf(`{"id":%q,"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.publisher.social"}]}`, g.did)), nil
	}
	g.listCalls++
	if g.invalidDocument {
		return 400, nil, []byte(`{"error":"InvalidRequest","message":"document serialization failed"}`), nil
	}
	return 200, nil, []byte(fmt.Sprintf(`{"records":[{"uri":%q,"cid":"fixture-list-cid","value":{"title":"List Page","publishedAt":"2026-10-06T12:00:00Z"}}],"cursor":"nonadvancing"}`, "at://"+g.did+"/site.standard.document/list-record")), nil
}

type restorationSnapshots struct {
	snapshot    thinappviewcore.RepositorySnapshot
	err         error
	calls       int
	dids        []string
	collections [][]string
}

func (s *restorationSnapshots) Read(_ context.Context, did string, collections []string) (thinappviewcore.RepositorySnapshot, error) {
	s.calls++
	s.dids = append(s.dids, did)
	s.collections = append(s.collections, append([]string(nil), collections...))
	return s.snapshot, s.err
}

func signedRestorationFixture(t *testing.T, db *sql.DB, scope thinappviewcore.RecoveryContext, records int) (RepositoryRestorer, *repeatingSnapshotHTTP, *restorationSnapshots) {
	t.Helper()
	getter := &repeatingSnapshotHTTP{did: scope.RepoDID}
	pds := &thinappviewcore.PDSClient{HTTP: getter}
	projector := &EventProjectorRuntime{DB: db, PDS: pds, Counters: thinappviewcore.CounterStore{DB: db}}
	source := &restorationSnapshots{snapshot: restorationSnapshot(scope.RepoDID, "commit-a", "revision-a", records)}
	return RepositoryRestorer{DB: db, PDS: pds, Projector: projector, Snapshots: source, RecordBudget: 20}, getter, source
}

func restorationSnapshot(did, commit, revision string, count int) thinappviewcore.RepositorySnapshot {
	snapshot := thinappviewcore.RepositorySnapshot{PDSBase: "https://pds.publisher.social", CommitCID: commit, Revision: revision, Records: []thinappviewcore.RepositorySnapshotRecord{}}
	for i := 0; i < count; i++ {
		collection := "site.standard.document"
		if i%2 == 1 {
			collection = "site.standard.entry"
		}
		snapshot.Records = append(snapshot.Records, thinappviewcore.RepositorySnapshotRecord{URI: fmt.Sprintf("at://%s/%s/snapshot-%s-%d", did, collection, revision, i), CID: fmt.Sprintf("fixture-%s-%d", revision, i), Value: json.RawMessage(`{"title":"Signed Snapshot","publishedAt":"2026-10-06T12:00:00Z"}`)})
	}
	return snapshot
}

func reloadSnapshotRecovery(t *testing.T, db *sql.DB, scope thinappviewcore.RecoveryContext) thinappviewcore.RecoveryState {
	t.Helper()
	var raw string
	if err := db.QueryRow(`SELECT recovery_state FROM appview_ingestion_inbox WHERE environment=$1 AND source_generation=$2 AND seq=$3`, scope.Environment, scope.SourceGeneration, scope.Sequence).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	var state thinappviewcore.RecoveryState
	if err := json.Unmarshal([]byte(raw), &state); err != nil {
		t.Fatal(err)
	}
	return state
}

func reclaimSnapshotRecovery(t *testing.T, db *sql.DB, scope *thinappviewcore.RecoveryContext) {
	t.Helper()
	scope.LeaseToken += "-next"
	if _, err := db.Exec(`UPDATE appview_ingestion_inbox SET status='leased',lease_owner=$2,lease_token=$3,lease_expires_at=$4 WHERE environment=$1`, scope.Environment, scope.WorkerID, scope.LeaseToken, time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
}

func TestSignedSnapshotFallbackResumesBoundedSlices(t *testing.T) {
	db := workerDatabase(t)
	scope, _ := seedRestorationScope(t, db)
	restorer, getter, source := signedRestorationFixture(t, db, scope, 45)
	ctx := context.Background()
	if err := restorer.Restore(ctx, scope); !errors.Is(err, thinappviewcore.ErrRecoveryYielded) {
		t.Fatalf("expected bounded fallback yield: %v", err)
	}
	first := reloadSnapshotRecovery(t, db, scope)
	if first.SnapshotMode != "signed_blocks_v1" || first.CommitCID != "commit-a" || first.Revision != "revision-a" || first.RecordOffset != 19 || first.Completed {
		t.Fatalf("invalid durable snapshot continuation: %+v", first)
	}
	var firstSliceRecords int
	if err := db.QueryRow(`SELECT COUNT(*) FROM content_items WHERE author_did=$1`, scope.RepoDID).Scan(&firstSliceRecords); err != nil || firstSliceRecords != restorer.RecordBudget {
		t.Fatalf("fallback exceeded overall restore slice budget: %d %v", firstSliceRecords, err)
	}
	var attempts int
	if err := db.QueryRow(`SELECT attempt_count FROM appview_ingestion_inbox WHERE environment=$1`, scope.Environment).Scan(&attempts); err != nil || attempts != 0 {
		t.Fatalf("successful slice consumed failure attempts: %d %v", attempts, err)
	}
	for slice := 0; slice < 2; slice++ {
		reclaimSnapshotRecovery(t, db, &scope)
		// Recreate the restorer; continuation must not depend on its instance.
		next := RepositoryRestorer{DB: db, PDS: restorer.PDS, Projector: restorer.Projector, Snapshots: source, RecordBudget: 20}
		err := next.Restore(ctx, scope)
		if slice == 0 && !errors.Is(err, thinappviewcore.ErrRecoveryYielded) {
			t.Fatalf("expected second slice yield: %v", err)
		}
		if slice == 1 && err != nil {
			t.Fatalf("last slice did not finish: %v", err)
		}
	}
	final := reloadSnapshotRecovery(t, db, scope)
	if !final.Completed || !final.PruningComplete || final.RecordOffset != 45 || final.SnapshotID != first.SnapshotID || !final.Collections["site.standard.document"].Complete || !final.Collections["site.standard.entry"].Complete {
		t.Fatalf("snapshot did not finish one coherent revision: %+v", final)
	}
	if getter.listCalls != 2 || source.calls != 3 {
		t.Fatalf("repeated list pagination was retried: list=%d snapshots=%d", getter.listCalls, source.calls)
	}
	for i, collections := range source.collections {
		if source.dids[i] != scope.RepoDID || len(collections) != 2 || collections[0] != "site.standard.document" || collections[1] != "site.standard.entry" {
			t.Fatalf("incorrect authoritative snapshot scope: %v", collections)
		}
	}
	var seen int
	if err := db.QueryRow(`SELECT COUNT(*) FROM content_items WHERE author_did=$1 AND uri LIKE '%/snapshot-revision-a-%'`, scope.RepoDID).Scan(&seen); err != nil || seen != 45 {
		t.Fatalf("snapshot records missing: %d %v", seen, err)
	}
}

func TestUnavailableSignedSnapshotPreservesIncompleteRecovery(t *testing.T) {
	db := workerDatabase(t)
	scope, _ := seedRestorationScope(t, db)
	restorer, _, source := signedRestorationFixture(t, db, scope, 45)
	source.err = errors.New("snapshot transport unavailable")
	missing := "at://" + scope.RepoDID + "/site.standard.document/previous-content"
	content := thinappviewcore.ContentStore{DB: db}
	if err := content.Upsert(context.Background(), thinappviewcore.IndexedContentItem{URI: missing, CID: "previous", AuthorDID: scope.RepoDID, Collection: "site.standard.document", CreatedAt: time.Now().Add(-time.Hour), IndexedAt: time.Now().Add(-time.Hour), ExpiresAt: time.Now().Add(time.Hour), Render: thinappviewcore.ContentRenderFields{Title: "Previous"}}); err != nil {
		t.Fatal(err)
	}
	if err := restorer.Restore(context.Background(), scope); !errors.Is(err, source.err) {
		t.Fatalf("unavailable snapshot accepted: %v", err)
	}
	state := reloadSnapshotRecovery(t, db, scope)
	if state.Completed || state.PruningComplete {
		t.Fatalf("unavailable snapshot completed recovery: %+v", state)
	}
	if exists, err := content.Exists(context.Background(), missing); err != nil || !exists {
		t.Fatalf("incomplete snapshot pruned prior content: %t %v", exists, err)
	}
	var reconciled bool
	if err := db.QueryRow(`SELECT reconciled_at IS NOT NULL FROM appview_ingestion_inbox WHERE environment=$1`, scope.Environment).Scan(&reconciled); err != nil || reconciled {
		t.Fatalf("unavailable snapshot cleared terminal barrier: %t %v", reconciled, err)
	}
}

func TestChangedSignedSnapshotRestartsObservationSet(t *testing.T) {
	db := workerDatabase(t)
	scope, _ := seedRestorationScope(t, db)
	restorer, _, source := signedRestorationFixture(t, db, scope, 45)
	if err := restorer.Restore(context.Background(), scope); !errors.Is(err, thinappviewcore.ErrRecoveryYielded) {
		t.Fatal(err)
	}
	first := reloadSnapshotRecovery(t, db, scope)
	source.snapshot = restorationSnapshot(scope.RepoDID, "commit-b", "revision-b", 25)
	reclaimSnapshotRecovery(t, db, &scope)
	if err := restorer.Restore(context.Background(), scope); !errors.Is(err, thinappviewcore.ErrRecoveryYielded) {
		t.Fatalf("changed revision did not restart bounded slice: %v", err)
	}
	second := reloadSnapshotRecovery(t, db, scope)
	if second.SnapshotID == first.SnapshotID || second.CommitCID != "commit-b" || second.Revision != "revision-b" || second.RecordOffset != 20 || second.Completed || !second.StartedAt.After(first.StartedAt.Time) {
		t.Fatalf("changed commit reused prior snapshot progress: %+v", second)
	}
	var mixed int
	if err := db.QueryRow(`SELECT COUNT(*) FROM appview_repository_recovery_records WHERE environment=$1 AND recovery_key=$2 AND uri LIKE '%/snapshot-revision-a-%'`, scope.Environment, fmt.Sprintf("sync:%d:%s", scope.Sequence, second.SnapshotID)).Scan(&mixed); err != nil || mixed != 0 {
		t.Fatalf("previous revision entered new observation set: %d %v", mixed, err)
	}
	// An event indexed after the new authoritative read began remains outside
	// that snapshot's pruning boundary, even if absent from its revision.
	concurrentURI := "at://" + scope.RepoDID + "/site.standard.document/concurrent"
	content := thinappviewcore.ContentStore{DB: db}
	if err := content.Upsert(context.Background(), thinappviewcore.IndexedContentItem{URI: concurrentURI, CID: "concurrent", AuthorDID: scope.RepoDID, Collection: "site.standard.document", CreatedAt: time.Now(), IndexedAt: time.Now(), ExpiresAt: time.Now().Add(time.Hour), Render: thinappviewcore.ContentRenderFields{Title: "Concurrent"}}); err != nil {
		t.Fatal(err)
	}
	reclaimSnapshotRecovery(t, db, &scope)
	if err := restorer.Restore(context.Background(), scope); err != nil {
		t.Fatal(err)
	}
	final := reloadSnapshotRecovery(t, db, scope)
	if !final.Completed || final.RecordOffset != 25 || final.Collections["site.standard.document"].IndexedCount+final.Collections["site.standard.entry"].IndexedCount != 25 {
		t.Fatalf("revision counts mixed during restart: %+v", final)
	}
	if exists, err := content.Exists(context.Background(), firstRecordURI(scope.RepoDID)); err != nil || exists {
		t.Fatalf("record absent from changed authoritative revision was retained: %t %v", exists, err)
	}
	if exists, err := content.Exists(context.Background(), concurrentURI); err != nil || !exists {
		t.Fatalf("changed snapshot pruned a concurrent event: %t %v", exists, err)
	}
}

func firstRecordURI(did string) string {
	return "at://" + did + "/site.standard.document/snapshot-revision-a-0"
}

func TestSignedSnapshotContinuationRejectsStaleLease(t *testing.T) {
	db := workerDatabase(t)
	scope, _ := seedRestorationScope(t, db)
	restorer, _, source := signedRestorationFixture(t, db, scope, 45)
	if err := restorer.Restore(context.Background(), scope); !errors.Is(err, thinappviewcore.ErrRecoveryYielded) {
		t.Fatal(err)
	}
	first := reloadSnapshotRecovery(t, db, scope)
	if _, err := db.Exec(`UPDATE appview_ingestion_inbox SET status='leased',lease_owner='replacement-worker',lease_token='replacement-token',lease_expires_at=$2 WHERE environment=$1`, scope.Environment, time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	calls := source.calls
	if err := restorer.Restore(context.Background(), scope); !errors.Is(err, thinappviewcore.ErrStaleInboxLease) {
		t.Fatalf("stale lease accepted: %v", err)
	}
	final := reloadSnapshotRecovery(t, db, scope)
	if final.RecordOffset != first.RecordOffset || final.SnapshotID != first.SnapshotID || final.Completed || source.calls != calls {
		t.Fatalf("stale owner advanced recovery: %+v", final)
	}
}

func TestSignedSnapshotFallbackAfterSingleDocumentInvalidRequest(t *testing.T) {
	db := workerDatabase(t)
	scope, _ := seedRestorationScope(t, db)
	restorer, getter, source := signedRestorationFixture(t, db, scope, 3)
	getter.invalidDocument = true
	if err := restorer.Restore(context.Background(), scope); err != nil {
		t.Fatalf("single-record serializer failure did not use authoritative snapshot: %v", err)
	}
	state := reloadSnapshotRecovery(t, db, scope)
	if getter.listCalls != 2 || source.calls != 1 || !state.Completed || state.RecordOffset != 3 || state.SnapshotMode != signedSnapshotMode {
		t.Fatalf("invalid single-page fallback result: list=%d snapshots=%d state=%+v", getter.listCalls, source.calls, state)
	}
}

func TestSignedSnapshotRecoveryCompletesActualWorkerBarrier(t *testing.T) {
	db := workerDatabase(t)
	ctx := context.Background()
	scope, _ := seedRestorationScope(t, db)
	restorer, _, _ := signedRestorationFixture(t, db, scope, 3)
	requestID := "signed-recovery-" + scope.Environment
	at := time.Now()
	if _, err := db.Exec(`UPDATE appview_ingestion_inbox SET status='dead_letter',dead_lettered_at=$2,lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL WHERE environment=$1`, scope.Environment, at); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO appview_ingestion_reconciliation_requests(environment,id,source_generation,repo_did,reason,trigger_seq,status,lease_owner,lease_token,lease_expires_at,created_at,updated_at)VALUES($1,$2,'fixture',$3,'fixture',1,'leased','worker','token',$4,$5,$5)`, scope.Environment, requestID, scope.RepoDID, at.Add(time.Minute), at); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO appview_jetstream_checkpoints(environment,source_generation,source_host,stream_nsid,filter_fingerprint,cursor_kind,last_staged_seq,last_staged_event_at,last_applied_seq,replay_state)VALUES($1,'fixture','fixture','fixture','fixture','jetstream_v2_seq',2,$2,0,'live')`, scope.Environment, at); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO appview_ingestion_inbox(environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,payload,event_time,status,applied_at)VALUES($1,'fixture',2,'fixture','jetstream_v2_seq','sync',$2,'{}',$3,'applied',$3)`, scope.Environment, scope.RepoDID, at); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO appview_ingestion_leases(environment,lease_name,source_generation,owner_id,fencing_token,acquired_at,lease_expires_at,updated_at)VALUES($1,'fixture','fixture','intake',1,$2,$3,$2)`, scope.Environment, at, at.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		db.Exec(`DELETE FROM appview_ingestion_leases WHERE environment=$1`, scope.Environment)
		db.Exec(`DELETE FROM operations_service_state WHERE environment=$1`, scope.Environment)
	})
	restorer.Projector.RestoreRepository = restorer.Restore
	readStateCalled := false
	restorer.Projector.ReconcileReadState = func(context.Context, string, bool) (bool, error) {
		readStateCalled = true
		return false, errors.New("unrelated read-state PDS unavailable")
	}
	h := Host{DB: db, Projector: restorer.Projector, Config: HostConfig{Environment: scope.Environment, Generation: scope.SourceGeneration, Role: "projection", InstanceID: scope.WorkerID, LeaseDuration: time.Minute, RestoreTimeout: time.Minute, AppliedRetention: time.Hour}}
	before, err := h.evidence(ctx, time.Now())
	if err != nil || before.Completeness != "unhealthy" || before.DeadLetters != 1 {
		t.Fatalf("fixture did not block completeness: %+v %v", before, err)
	}
	if err := (thinappviewcore.InboxStore{DB: db}).AdvanceAppliedWatermark(ctx, scope.Environment, scope.SourceGeneration, time.Now()); err != nil {
		t.Fatal(err)
	}
	var prefix int64
	if err := db.QueryRow(`SELECT last_applied_seq FROM appview_jetstream_checkpoints WHERE environment=$1`, scope.Environment).Scan(&prefix); err != nil || prefix != 0 {
		t.Fatalf("incomplete sync barrier was skipped: %d %v", prefix, err)
	}
	h.processReconciliation(ctx, thinappviewcore.ReconciliationRequest{Environment: scope.Environment, SourceGeneration: scope.SourceGeneration, ID: requestID, RepoDID: scope.RepoDID, TriggerSequence: scope.Sequence, LeaseToken: scope.LeaseToken})
	var status string
	var complete, reconciled bool
	if err := db.QueryRow(`SELECT status,recovery_state::jsonb->>'completed'='true' FROM appview_ingestion_reconciliation_requests WHERE environment=$1 AND id=$2`, scope.Environment, requestID).Scan(&status, &complete); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`SELECT reconciled_at IS NOT NULL FROM appview_ingestion_inbox WHERE environment=$1 AND seq=1`, scope.Environment).Scan(&reconciled); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`SELECT last_applied_seq FROM appview_jetstream_checkpoints WHERE environment=$1`, scope.Environment).Scan(&prefix); err != nil {
		t.Fatal(err)
	}
	if status != "completed" || !complete || !reconciled || prefix != 2 || readStateCalled {
		t.Fatalf("actual content recovery failed: status=%s complete=%t reconciled=%t prefix=%d readState=%t", status, complete, reconciled, prefix, readStateCalled)
	}
	after, err := h.evidence(ctx, time.Now())
	if err != nil || after.Completeness != "healthy" || after.DeadLetters != 0 {
		t.Fatalf("genuine recovery did not clear completeness: %+v %v", after, err)
	}
	// Operations service-state environments are constrained to actual environment
	// names; keep the unique ingestion fixture scope and isolated heartbeat ID.
	h.Config.Environment = "dev"
	h.Config.InstanceID = "signed-heartbeat-" + scope.Environment
	t.Cleanup(func() {
		db.Exec(`DELETE FROM operations_service_state WHERE environment='dev' AND instance_id=$1`, h.Config.InstanceID)
	})
	now := time.Now()
	if err := h.publishHeartbeat(ctx, after, nil, now, now); err != nil {
		t.Fatal(err)
	}
	if err := h.checkReadiness(ctx); err != nil {
		t.Fatalf("completed genuine recovery not ready: %v", err)
	}
}
