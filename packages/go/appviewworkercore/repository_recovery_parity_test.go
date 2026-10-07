package appviewworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

type pagedRestorationHTTP struct {
	did            string
	total, calls   int
	fail           bool
	singleDocument bool
	allowReverse   bool
	rejectCode     string
	failSmall      bool
	oversizeSmall  bool
	smallCalls     int
	served         []int
}

func (g *pagedRestorationHTTP) Get(_ context.Context, raw string, _ http.Header, _ int, _ int) (int, http.Header, []byte, error) {
	g.calls++
	if g.fail {
		return 503, nil, nil, nil
	}
	u, _ := url.Parse(raw)
	if strings.HasSuffix(u.Path, "/did.json") {
		return 200, nil, []byte(fmt.Sprintf(`{"id":%q,"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.publisher.social"}]}`, g.did)), nil
	}
	if u.Query().Get("collection") == "site.standard.entry" {
		return 200, nil, []byte(`{"records":[]}`), nil
	}
	if g.singleDocument {
		if u.Query().Get("reverse") == "true" && !g.allowReverse {
			return 400, nil, []byte(`{"error":"UnsupportedReverse","message":"reverse not supported"}`), nil
		}
		if u.Query().Get("limit") != "1" {
			code := g.rejectCode
			if code == "" {
				code = "InvalidRequest"
			}
			body, _ := json.Marshal(map[string]string{"error": code, "message": "document page unavailable"})
			return 400, nil, body, nil
		}
		g.smallCalls++
		if u.Query().Get("reverse") != "" {
			return 400, nil, []byte(`{"error":"InvalidRequest"}`), nil
		}
		if g.failSmall {
			return 400, nil, []byte(`{"error":"InvalidRequest"}`), nil
		}
	}
	start, _ := strconv.Atoi(u.Query().Get("cursor"))
	limit, _ := strconv.Atoi(u.Query().Get("limit"))
	if g.singleDocument && g.oversizeSmall {
		limit = 2
	}
	end := min(start+limit, g.total)
	records := []map[string]any{}
	for i := start; i < end; i++ {
		g.served = append(g.served, i)
		records = append(records, map[string]any{"uri": fmt.Sprintf("at://%s/site.standard.document/record%d", g.did, i), "cid": "fixture-cid", "value": map[string]any{"title": "Snapshot", "publishedAt": "2026-10-06T12:00:00Z"}})
	}
	page := map[string]any{"records": records}
	if end < g.total {
		page["cursor"] = strconv.Itoa(end)
	}
	body, err := json.Marshal(page)
	return 200, nil, body, err
}

func seedRestorationScope(t *testing.T, db *sql.DB) (thinappviewcore.RecoveryContext, string) {
	t.Helper()
	nonce, err := newSnapshotToken()
	if err != nil {
		t.Fatal(err)
	}
	scope := thinappviewcore.RecoveryContext{Environment: "restore-parity-" + nonce, SourceGeneration: "fixture", Sequence: 1, RepoDID: "did:web:publisher.social:" + nonce, WorkerID: "worker", LeaseToken: "token"}
	viewer := "viewer-" + nonce
	at := time.Now()
	t.Cleanup(func() {
		db.Exec("DELETE FROM appview_repository_recovery_records WHERE environment=$1", scope.Environment)
		db.Exec("DELETE FROM appview_ingestion_reconciliation_requests WHERE environment=$1", scope.Environment)
		db.Exec("DELETE FROM appview_ingestion_inbox WHERE environment=$1", scope.Environment)
		db.Exec("DELETE FROM appview_jetstream_checkpoints WHERE environment=$1", scope.Environment)
		db.Exec("DELETE FROM content_items WHERE author_did=$1", scope.RepoDID)
		db.Exec("DELETE FROM appview_unread_counters WHERE viewer_did=$1", viewer)
		db.Exec("DELETE FROM appview_publication_scopes WHERE viewer_did=$1", viewer)
	})
	if _, err = db.Exec(`INSERT INTO appview_ingestion_inbox(environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,payload,event_time,status,lease_owner,lease_token,lease_expires_at)VALUES($1,'fixture',1,'fixture','jetstream_v2_seq','sync',$2,'{}',$3,'leased','worker','token',$4)`, scope.Environment, scope.RepoDID, at, at.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	return scope, viewer
}

func TestRestorationCapsSlicesAndResumesWithoutFailureAttempts(t *testing.T) {
	db := workerDatabase(t)
	ctx := context.Background()
	scope, _ := seedRestorationScope(t, db)
	getter := &pagedRestorationHTTP{did: scope.RepoDID, total: 241}
	pds := &thinappviewcore.PDSClient{HTTP: getter}
	projector := &EventProjectorRuntime{DB: db, PDS: pds, Counters: thinappviewcore.CounterStore{DB: db}}
	restorer := RepositoryRestorer{DB: db, PDS: pds, Projector: projector, RecordBudget: 2000}
	if err := restorer.Restore(ctx, scope); !errors.Is(err, thinappviewcore.ErrRecoveryYielded) {
		t.Fatalf("expected bounded yield: %v", err)
	}
	var status string
	var attempts int
	var raw string
	if err := db.QueryRow(`SELECT status,attempt_count,recovery_state FROM appview_ingestion_inbox WHERE environment=$1`, scope.Environment).Scan(&status, &attempts, &raw); err != nil {
		t.Fatal(err)
	}
	var state thinappviewcore.RecoveryState
	if err := json.Unmarshal([]byte(raw), &state); err != nil {
		t.Fatal(err)
	}
	if status != "retry" || attempts != 0 || state.Collections["site.standard.document"].IndexedCount != 200 || state.Completed {
		t.Fatalf("incorrect first slice: %s %d %+v", status, attempts, state)
	}
	// Recreating the restorer and PDS client proves the continuation is durable, not process-local.
	if _, err := db.Exec(`UPDATE appview_ingestion_inbox SET status='leased',lease_owner='worker',lease_token='replacement',lease_expires_at=$2 WHERE environment=$1`, scope.Environment, time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	scope.LeaseToken = "replacement"
	pds = &thinappviewcore.PDSClient{HTTP: getter}
	projector.PDS = pds
	restorer = RepositoryRestorer{DB: db, PDS: pds, Projector: projector, RecordBudget: 2000}
	if err := restorer.Restore(ctx, scope); err != nil {
		t.Fatal(err)
	}
	state, err := (thinappviewcore.RecoveryStore{DB: db}).Load(ctx, scope)
	if err != nil {
		t.Fatal(err)
	}
	if !state.Completed || state.Collections["site.standard.document"].IndexedCount != 241 {
		t.Fatalf("bad resumed state: %+v", state)
	}
	if err := db.QueryRow(`SELECT attempt_count FROM appview_ingestion_inbox WHERE environment=$1`, scope.Environment).Scan(&attempts); err != nil || attempts != 0 {
		t.Fatalf("yield spent attempts: %d %v", attempts, err)
	}
}

func TestCompletedRestorationRetriesDirtyAndCacheWithoutRefetchOrPrune(t *testing.T) {
	db := workerDatabase(t)
	ctx := context.Background()
	scope, viewer := seedRestorationScope(t, db)
	if _, err := db.Exec(`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,scope_keys)VALUES($1,'different-site',$2,'["https://other.example/site"]')`, viewer, scope.RepoDID); err != nil {
		t.Fatal(err)
	}
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr(), MaxRetries: -1})
	t.Cleanup(func() { client.Close() })
	namespace := socialwireredis.NewKeyNamespace("dev", "")
	cache := &thinappviewcore.ProjectionCache{Redis: client, Namespace: namespace}
	getter := &pagedRestorationHTTP{did: scope.RepoDID, total: 1}
	pds := &thinappviewcore.PDSClient{HTTP: getter}
	projector := &EventProjectorRuntime{DB: db, PDS: pds, Counters: thinappviewcore.CounterStore{DB: db}}
	// Populate content without a cache; finalization is then the only failing cache operation.
	restorer := RepositoryRestorer{DB: db, PDS: pds, Projector: projector, RecordBudget: 200}
	if err := restorer.Restore(ctx, scope); err != nil {
		t.Fatal(err)
	}
	projector.Cache = cache
	server.SetError("fixture cache unavailable")
	if err := restorer.Restore(ctx, scope); err == nil {
		t.Fatal("cache invalidation failure was swallowed")
	}
	calls := getter.calls
	getter.fail = true
	if _, err := db.Exec(`UPDATE appview_unread_counters SET dirty=false,unread_count=7 WHERE viewer_did=$1`, viewer); err != nil {
		t.Fatal(err)
	}
	// A row arriving after snapshot completion must never be pruned during finalization retry.
	lateURI := "at://" + scope.RepoDID + "/site.standard.document/late"
	if err := (thinappviewcore.ContentStore{DB: db}).Upsert(ctx, thinappviewcore.IndexedContentItem{URI: lateURI, CID: "late", AuthorDID: scope.RepoDID, Collection: "site.standard.document", CreatedAt: time.Now().Add(-time.Hour), IndexedAt: time.Now().Add(-time.Hour), ExpiresAt: time.Now().Add(time.Hour), Render: thinappviewcore.ContentRenderFields{Title: "Late"}}); err != nil {
		t.Fatal(err)
	}
	server.SetError("")
	key := namespace.Key("sidebar", nil, []string{viewer})
	server.Set(key, "stale")
	if err := restorer.Restore(ctx, scope); err != nil {
		t.Fatal(err)
	}
	if getter.calls != calls {
		t.Fatal("completed checkpoint refetched PDS")
	}
	if exists, err := (thinappviewcore.ContentStore{DB: db}).Exists(ctx, lateURI); err != nil || !exists {
		t.Fatalf("completed checkpoint repruned content: %t %v", exists, err)
	}
	var dirty bool
	var count int
	if err := db.QueryRow(`SELECT dirty,unread_count FROM appview_unread_counters WHERE viewer_did=$1`, viewer).Scan(&dirty, &count); err != nil {
		t.Fatal(err)
	}
	if !dirty || count != 7 || server.Exists(key) {
		t.Fatalf("finalization not retried: dirty=%t count=%d cache=%t", dirty, count, server.Exists(key))
	}
}

func TestTargetedReconciliationDoesNotRequireReadState(t *testing.T) {
	db := workerDatabase(t)
	ctx := context.Background()
	scope, _ := seedRestorationScope(t, db)
	requestID := "request-" + scope.Environment
	if _, err := db.Exec(`UPDATE appview_ingestion_inbox SET status='dead_letter',dead_lettered_at=NOW(),lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL WHERE environment=$1`, scope.Environment); err != nil {
		t.Fatal(err)
	}
	at := time.Now()
	if _, err := db.Exec(`INSERT INTO appview_ingestion_reconciliation_requests(environment,id,source_generation,repo_did,reason,trigger_seq,status,lease_owner,lease_token,lease_expires_at,created_at,updated_at)VALUES($1,$2,'fixture',$3,'fixture',1,'leased','worker','token',$4,$5,$5)`, scope.Environment, requestID, scope.RepoDID, at.Add(time.Minute), at); err != nil {
		t.Fatal(err)
	}
	scope.RequestID = &requestID
	getter := &pagedRestorationHTTP{did: scope.RepoDID, total: 1}
	pds := &thinappviewcore.PDSClient{HTTP: getter}
	projector := &EventProjectorRuntime{DB: db, PDS: pds, Counters: thinappviewcore.CounterStore{DB: db}}
	restorer := RepositoryRestorer{DB: db, PDS: pds, Projector: projector, RecordBudget: 200}
	projector.RestoreRepository = restorer.Restore
	called := false
	projector.ReconcileReadState = func(context.Context, string, bool) (bool, error) {
		called = true
		return false, errors.New("unavailable read-state PDS")
	}
	h := Host{DB: db, Projector: projector, Config: HostConfig{InstanceID: "worker", LeaseDuration: time.Minute, RestoreTimeout: time.Minute, AppliedRetention: time.Hour}}
	h.processReconciliation(ctx, thinappviewcore.ReconciliationRequest{Environment: scope.Environment, SourceGeneration: scope.SourceGeneration, ID: requestID, RepoDID: scope.RepoDID, TriggerSequence: 1, LeaseToken: "token"})
	var status string
	var attempts int
	if err := db.QueryRow(`SELECT status,attempt_count FROM appview_ingestion_reconciliation_requests WHERE environment=$1`, scope.Environment).Scan(&status, &attempts); err != nil {
		t.Fatal(err)
	}
	var reconciled bool
	if err := db.QueryRow(`SELECT reconciled_at IS NOT NULL FROM appview_ingestion_inbox WHERE environment=$1`, scope.Environment).Scan(&reconciled); err != nil {
		t.Fatal(err)
	}
	if called || status != "completed" || attempts != 0 || !reconciled {
		t.Fatalf("targeted content recovery blocked: read-state=%t status=%s attempts=%d reconciled=%t", called, status, attempts, reconciled)
	}
}

func TestSingleDocumentPageFallbackYieldsAndResumes(t *testing.T) {
	db := workerDatabase(t)
	ctx := context.Background()
	scope, _ := seedRestorationScope(t, db)
	getter := &pagedRestorationHTTP{did: scope.RepoDID, total: 25, singleDocument: true}
	pds := &thinappviewcore.PDSClient{HTTP: getter}
	projector := &EventProjectorRuntime{DB: db, PDS: pds, Counters: thinappviewcore.CounterStore{DB: db}}
	restorer := RepositoryRestorer{DB: db, PDS: pds, Projector: projector, RecordBudget: 2000}
	if err := restorer.Restore(ctx, scope); !errors.Is(err, thinappviewcore.ErrRecoveryYielded) {
		t.Fatalf("expected page-budget yield: %v", err)
	}
	var raw, status string
	var attempts int
	if err := db.QueryRow(`SELECT status,attempt_count,recovery_state FROM appview_ingestion_inbox WHERE environment=$1`, scope.Environment).Scan(&status, &attempts, &raw); err != nil {
		t.Fatal(err)
	}
	var state thinappviewcore.RecoveryState
	if err := json.Unmarshal([]byte(raw), &state); err != nil {
		t.Fatal(err)
	}
	saved := state.Collections["site.standard.document"]
	if status != "retry" || attempts != 0 || saved.IndexedCount != 20 || saved.Cursor == nil || *saved.Cursor != "20" || getter.smallCalls != 20 {
		t.Fatalf("bad small-page slice: %s %d %+v calls=%d", status, attempts, saved, getter.smallCalls)
	}
	if _, err := db.Exec(`UPDATE appview_ingestion_inbox SET status='leased',lease_owner='worker',lease_token='next',lease_expires_at=$2 WHERE environment=$1`, scope.Environment, time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	scope.LeaseToken = "next"
	pds = &thinappviewcore.PDSClient{HTTP: getter}
	projector.PDS = pds
	restorer = RepositoryRestorer{DB: db, PDS: pds, Projector: projector, RecordBudget: 2000}
	if err := restorer.Restore(ctx, scope); err != nil {
		t.Fatal(err)
	}
	if len(getter.served) != 25 {
		t.Fatalf("replayed or skipped pages: %v", getter.served)
	}
	for index, value := range getter.served {
		if index != value {
			t.Fatalf("duplicate/skipped page at %d: %v", index, getter.served)
		}
	}
	state, err := (thinappviewcore.RecoveryStore{DB: db}).Load(ctx, scope)
	if err != nil || !state.Completed || state.Collections["site.standard.document"].IndexedCount != 25 {
		t.Fatalf("resume not completed: %+v %v", state, err)
	}
	if err := db.QueryRow(`SELECT attempt_count FROM appview_ingestion_inbox WHERE environment=$1`, scope.Environment).Scan(&attempts); err != nil || attempts != 0 {
		t.Fatalf("small pages consumed failures: %d %v", attempts, err)
	}
}

func TestDocumentFallbackDoesNotHideInvalidResponses(t *testing.T) {
	for _, test := range []struct {
		name, code    string
		failSmall     bool
		oversizeSmall bool
		wantSmall     int
	}{
		{"other_400", "NotAuthorized", false, false, 0},
		{"still_invalid_at_one", "InvalidRequest", true, false, 1},
		{"oversized_limit_one_page", "InvalidRequest", false, true, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			db := workerDatabase(t)
			scope, _ := seedRestorationScope(t, db)
			getter := &pagedRestorationHTTP{did: scope.RepoDID, total: 2, singleDocument: true, rejectCode: test.code, failSmall: test.failSmall, oversizeSmall: test.oversizeSmall}
			pds := &thinappviewcore.PDSClient{HTTP: getter}
			projector := &EventProjectorRuntime{DB: db, PDS: pds, Counters: thinappviewcore.CounterStore{DB: db}}
			err := (RepositoryRestorer{DB: db, PDS: pds, Projector: projector, RecordBudget: 200}).Restore(context.Background(), scope)
			if err == nil || errors.Is(err, thinappviewcore.ErrRecoveryYielded) {
				t.Fatalf("invalid page accepted: %v", err)
			}
			if getter.smallCalls != test.wantSmall {
				t.Fatalf("fallback requests: %d want %d", getter.smallCalls, test.wantSmall)
			}
			state, err := (thinappviewcore.RecoveryStore{DB: db}).Load(context.Background(), scope)
			if err != nil || state.Completed || len(state.Collections) != 0 {
				t.Fatalf("failed page advanced checkpoint: %+v %v", state, err)
			}
		})
	}
}

func TestRestorationYieldsSavedProgressBeforeStartingPageNearDeadline(t *testing.T) {
	db := workerDatabase(t)
	scope, _ := seedRestorationScope(t, db)
	getter := &pagedRestorationHTTP{did: scope.RepoDID, total: 25}
	pds := &thinappviewcore.PDSClient{HTTP: getter}
	projector := &EventProjectorRuntime{DB: db, PDS: pds, Counters: thinappviewcore.CounterStore{DB: db}}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	err := (RepositoryRestorer{DB: db, PDS: pds, Projector: projector, RecordBudget: 200}).Restore(ctx, scope)
	if !errors.Is(err, thinappviewcore.ErrRecoveryYielded) {
		t.Fatalf("expected saved checkpoint yield: %v", err)
	}
	var raw string
	var attempts int
	if err := db.QueryRow(`SELECT attempt_count,recovery_state FROM appview_ingestion_inbox WHERE environment=$1`, scope.Environment).Scan(&attempts, &raw); err != nil {
		t.Fatal(err)
	}
	var state thinappviewcore.RecoveryState
	if err := json.Unmarshal([]byte(raw), &state); err != nil {
		t.Fatal(err)
	}
	if attempts != 0 || state.Collections["site.standard.document"].IndexedCount != 10 || len(getter.served) != 10 {
		t.Fatalf("deadline guard lost progress or spent attempts: %d %+v served=%v", attempts, state, getter.served)
	}
}

func TestDocumentPageLimitFallbackSwitchesToForwardOnGenericInvalidRequest(t *testing.T) {
	db := workerDatabase(t)
	scope, _ := seedRestorationScope(t, db)
	getter := &pagedRestorationHTTP{did: scope.RepoDID, total: 1, singleDocument: true, allowReverse: true}
	pds := &thinappviewcore.PDSClient{HTTP: getter}
	projector := &EventProjectorRuntime{DB: db, PDS: pds, Counters: thinappviewcore.CounterStore{DB: db}}
	if err := (RepositoryRestorer{DB: db, PDS: pds, Projector: projector, RecordBudget: 200}).Restore(context.Background(), scope); err != nil {
		t.Fatal(err)
	}
	if getter.smallCalls != 1 || len(getter.served) != 1 {
		t.Fatalf("forward limit-one fallback not applied: calls=%d served=%v", getter.smallCalls, getter.served)
	}
}
