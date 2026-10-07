package appviewworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

const recoveryFixtureDID = "did:plc:abcdefghijklmnopqrstuvwx"

type recoveryFixtureGetter struct {
	pages     int
	malformed bool
	cap       bool
	started   chan struct{}
	blocked   bool
}

func (g *recoveryFixtureGetter) Get(ctx context.Context, raw string, _ http.Header, _ int, _ int) (int, http.Header, []byte, error) {
	u, _ := url.Parse(raw)
	if u.Host == "plc.directory" {
		body, _ := json.Marshal(map[string]any{"id": recoveryFixtureDID, "service": []any{map[string]any{"id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": "https://recovery.publisher.social"}}})
		return 200, nil, body, nil
	}
	g.pages++
	if g.started != nil {
		select {
		case g.started <- struct{}{}:
		default:
		}
	}
	if g.blocked {
		<-ctx.Done()
		return 0, nil, nil, ctx.Err()
	}
	if g.malformed {
		return 200, nil, []byte(`{"records":[{"uri":"at://wrong/site.standard.document/r","cid":"cid","value":{}}]}`), nil
	}
	records := []any{map[string]any{"uri": "at://" + recoveryFixtureDID + "/site.standard.document/recovery-fixture", "cid": "cid", "value": map[string]any{"title": "Recovery fixture", "url": "https://recovery.publisher.social/article", "publishedAt": time.Now().UTC().Format(time.RFC3339)}}}
	value := map[string]any{"records": records}
	if g.cap {
		value["cursor"] = "next"
	}
	body, _ := json.Marshal(value)
	return 200, nil, body, nil
}
func recoveryEngineFixture(t *testing.T, source string, getter thinappviewcore.PublicGetter) (*RecoveryEngine, BackfillJob, *sql.DB) {
	t.Helper()
	db := workerDatabase(t)
	nonce, _ := newSnapshotToken()
	at := time.Now().UTC()
	authority := operationscore.RoleLeaseAuthority{Environment: "dev", Role: "go-executor-" + nonce, OwnerID: nonce, FencingToken: 1}
	store := BackfillStore{DB: db, Authority: authority, Environment: "dev", WorkerID: nonce}
	t.Cleanup(func() {
		db.Exec(`DELETE FROM operations_audit_events WHERE environment='dev'AND target_id=$1`, nonce)
		db.Exec(`DELETE FROM operations_idempotency_records WHERE environment='dev'AND target_id=$1`, nonce)
		db.Exec(`DELETE FROM appview_recovery_failures WHERE job_id=$1`, nonce)
		db.Exec(`DELETE FROM appview_backfill_jobs WHERE id=$1`, nonce)
		db.Exec(`DELETE FROM operations_role_leases WHERE role=$1`, authority.Role)
		db.Exec(`DELETE FROM content_items WHERE author_did=$1`, recoveryFixtureDID)
	})
	if _, err := db.Exec(`INSERT INTO operations_role_leases(environment,role,owner_id,fencing_token,acquired_at,lease_expires_at,updated_at)VALUES('dev',$1,$2,1,$3,$4,$3)`, authority.Role, nonce, at, at.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO appview_backfill_jobs(environment,id,source_mode,status,start_cursor,end_cursor,collections,author_dids,batch_size,rate_limit,max_concurrency,requested_by_did,audit_note,created_at,updated_at,lease_owner,lease_expires_at)VALUES('dev',$1,$2,'running',$3,$4,'["site.standard.document"]','["did:plc:abcdefghijklmnopqrstuvwx"]',1,1000,1,'did:plc:abcdefghijklmnopqrstuvwx','test',$5,$5,$1,$6)`, nonce, source, int64(100), int64(200), at, at.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	job, err := scanBackfill(db.QueryRow(`SELECT `+backfillColumns+` FROM appview_backfill_jobs WHERE id=$1`, nonce))
	if err != nil {
		t.Fatal(err)
	}
	pds := &thinappviewcore.PDSClient{HTTP: getter}
	projector := &EventProjectorRuntime{DB: db, PDS: pds, Counters: thinappviewcore.CounterStore{DB: db}}
	engine := &RecoveryEngine{Store: store, PDS: pds, Projector: projector, RelayURL: "wss://relay.publisher.social/subscribe", MaximumAuthors: 500, RecordCapPerAuthor: 2000, HeartbeatInterval: 10 * time.Millisecond}
	return engine, job, db
}
func TestRecoveryPDSProjectionAndDiagnosticReports(t *testing.T) {
	for _, test := range []struct {
		name              string
		malformed, cap    bool
		processed, failed int
		truncated         bool
	}{{"success", false, false, 1, 0, false}, {"malformed", true, false, 1, 1, false}, {"record cap", false, true, 2, 1, true}} {
		t.Run(test.name, func(t *testing.T) {
			getter := &recoveryFixtureGetter{malformed: test.malformed, cap: test.cap}
			engine, job, db := recoveryEngineFixture(t, "pds_reconciliation", getter)
			if test.cap {
				engine.RecordCapPerAuthor = 1
			}
			if err := engine.Execute(context.Background(), job); err != nil {
				t.Fatal(err)
			}
			var status, verification, results string
			var processed, failed int
			var truncated bool
			if err := db.QueryRow(`SELECT status,verification_status,author_results::text,processed_count,failed_count,scope_truncated FROM appview_backfill_jobs WHERE id=$1`, job.ID).Scan(&status, &verification, &results, &processed, &failed, &truncated); err != nil {
				t.Fatal(err)
			}
			if status != "completed" || verification != "required" || processed != test.processed || failed != test.failed || truncated != test.truncated {
				t.Fatalf("state %s %s %d %d %v", status, verification, processed, failed, truncated)
			}
			var reports []BackfillAuthorResult
			if json.Unmarshal([]byte(results), &reports) != nil || len(reports) != 1 {
				t.Fatal(results)
			}
			if reports[0].DID != recoveryFixtureDID {
				t.Fatal(reports)
			}
		})
	}
}
func TestRecoveryPauseCancelsInFlightTransportAndKeepsOperatorState(t *testing.T) {
	getter := &recoveryFixtureGetter{blocked: true, started: make(chan struct{}, 1)}
	engine, job, db := recoveryEngineFixture(t, "pds_reconciliation", getter)
	done := make(chan error, 1)
	go func() { done <- engine.Execute(context.Background(), job) }()
	select {
	case <-getter.started:
	case <-time.After(time.Second):
		t.Fatal("fetch not started")
	}
	if _, err := db.Exec(`UPDATE appview_backfill_jobs SET status='paused',version=version+1 WHERE id=$1`, job.ID); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("pause did not cancel and join fetch")
	}
	var status string
	if err := db.QueryRow(`SELECT status FROM appview_backfill_jobs WHERE id=$1`, job.ID).Scan(&status); err != nil || status != "paused" {
		t.Fatalf("operator state %s %v", status, err)
	}
}

type fixedRecoveryReplay struct {
	messages []string
	failure  error
}

func (r fixedRecoveryReplay) Consume(ctx context.Context, _ string, handle func([]byte) error) error {
	for _, message := range r.messages {
		if err := handle([]byte(message)); err != nil {
			return err
		}
	}
	if r.failure != nil {
		return r.failure
	}
	return nil
}
func TestRecoveryReplayUpperBoundAndIncompleteFailure(t *testing.T) {
	for _, complete := range []bool{true, false} {
		t.Run(map[bool]string{true: "complete", false: "incomplete"}[complete], func(t *testing.T) {
			engine, job, db := recoveryEngineFixture(t, "jetstream_replay", &recoveryFixtureGetter{})
			message := `{"time_us":150,"kind":"commit","did":"` + recoveryFixtureDID + `","commit":{"collection":"site.standard.document","rkey":"replay","operation":"create","cid":"cid","record":{"title":"Replay","url":"https://recovery.publisher.social/replay"}}}`
			messages := []string{`{"time_us":100}`, message}
			if complete {
				messages = append(messages, `{"time_us":201}`)
			}
			engine.Replay = fixedRecoveryReplay{messages: messages}
			err := engine.Execute(context.Background(), job)
			if complete && err != nil {
				t.Fatal(err)
			}
			if !complete && err == nil {
				t.Fatal("premature transport end succeeded")
			}
			var status, verification string
			var cursor int64
			if err = db.QueryRow(`SELECT status,verification_status,checkpoint_cursor FROM appview_backfill_jobs WHERE id=$1`, job.ID).Scan(&status, &verification, &cursor); err != nil {
				t.Fatal(err)
			}
			expected := "completed"
			if !complete {
				expected = "failed"
			}
			if status != expected || cursor != 150 || complete && verification != "required" {
				t.Fatalf("replay state %s %s %d", status, verification, cursor)
			}
		})
	}
}
func TestReplayCursorAndFailureRedaction(t *testing.T) {
	for _, raw := range []string{`-1`, `"bad"`, `1.5`, `null`} {
		if _, ok := replayEnvelopeCursor([]byte(raw)); ok {
			t.Fatal(raw)
		}
	}
	if cursor, ok := replayEnvelopeCursor([]byte(`"9007199254740993"`)); !ok || cursor != 9007199254740993 {
		t.Fatal(cursor, ok)
	}
	if len(recoveryIdentityHash("private identity")) != 24 || strings.Contains(recoveryErrorCategory(errors.New("secret response")), "secret") {
		t.Fatal("unsafe diagnostic metadata")
	}
}

func TestRecoveryReplayFailureNeverAdvancesFailedCursor(t *testing.T) {
	engine, job, db := recoveryEngineFixture(t, "jetstream_replay", &recoveryFixtureGetter{})
	base := `{"kind":"commit","did":"` + recoveryFixtureDID + `","commit":{"collection":"site.standard.document","rkey":"replay","operation":"create","cid":"cid","record":`
	engine.Replay = fixedRecoveryReplay{messages: []string{`{"time_us":150,` + base[1:] + `{"title":"Before failure","url":"https://recovery.publisher.social/replay"}}}`, `{"time_us":175,` + base[1:] + `[]}}`}}
	if err := engine.Execute(context.Background(), job); err == nil {
		t.Fatal("failed projection reported success")
	}
	var cursor int64
	var processed, failed int
	var status string
	if err := db.QueryRow(`SELECT checkpoint_cursor,processed_count,failed_count,status FROM appview_backfill_jobs WHERE id=$1`, job.ID).Scan(&cursor, &processed, &failed, &status); err != nil {
		t.Fatal(err)
	}
	if cursor != 150 || processed != 2 || failed != 1 || status != "failed" {
		t.Fatalf("failed cursor state %d %d %d %s", cursor, processed, failed, status)
	}
}
