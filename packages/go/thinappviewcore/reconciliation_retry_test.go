package thinappviewcore

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestOperatorReconciliationRetryRejectsUnboundedScope(t *testing.T) {
	for _, scope := range []struct {
		env, generation string
		count           int
	}{
		{"", "generation", 1}, {"local", "generation", 1},
		{"prod", "", 1}, {"prod", "wildcard*", 1},
		{"prod", "generation", 0}, {"prod", "generation", 101},
	} {
		if _, err := (InboxStore{}).OperatorRetryFailedReconciliations(context.Background(), scope.env, scope.generation, scope.count, time.Now()); !errors.Is(err, ErrReconciliationRetryScope) {
			t.Fatal("unsafe scope admitted", err)
		}
	}
}

func TestPostgresOperatorRetryPreservesReconciliationEvidence(t *testing.T) {
	db := inboxDatabase(t)
	ctx := context.Background()
	nonce, err := inboxLeaseToken()
	if err != nil {
		t.Fatal(err)
	}
	gen := "operator-retry-" + nonce
	at := time.Now().UTC().Truncate(time.Microsecond)
	t.Cleanup(func() {
		for _, table := range []string{"appview_repository_recovery_records", "appview_ingestion_reconciliation_requests", "appview_ingestion_inbox", "appview_jetstream_checkpoints"} {
			if _, err := db.Exec("DELETE FROM "+table+" WHERE source_generation=$1", gen); err != nil {
				t.Errorf("cleanup fixture: %v", err)
			}
		}
	})
	execute := func(query string, args ...any) {
		t.Helper()
		if _, err := db.Exec(query, args...); err != nil {
			t.Fatal(err)
		}
	}
	// Requests 1/2 qualify. Others prove that neither partial recovery nor a
	// matching identity outside the exact scope is permission to retry.
	for seq := 1; seq <= 9; seq++ {
		env := "prod"
		if seq == 8 {
			env = "dev"
		}
		did := "did:plc:fixture-" + nonce
		inboxDID := did
		if seq == 5 {
			inboxDID += "-different"
		}
		status := "dead_letter"
		if seq == 4 {
			status = "pending"
		}
		var reconciled any
		if seq == 3 {
			reconciled = at
		}
		execute(`INSERT INTO appview_ingestion_inbox(environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,payload,event_time,status,attempt_count,dead_lettered_at,reconciled_at,recovery_state)
VALUES($1,$2,$3,'fixture','jetstream_v2_seq','commit',$4,'{}',$5,$6,12,$5,$7,'inbox-checkpoint-byte-for-byte')`, env, gen, seq, inboxDID, at, status, reconciled)
		requestStatus := "failed"
		if seq == 6 {
			requestStatus = "pending"
		} else if seq == 7 {
			requestStatus = "completed"
		}
		trigger := seq
		if seq == 9 {
			trigger += 100
		}
		execute(`INSERT INTO appview_ingestion_reconciliation_requests(environment,id,source_generation,repo_did,reason,trigger_seq,status,attempt_count,next_attempt_at,lease_owner,lease_token,lease_expires_at,created_at,updated_at,completed_at,recovery_state)
VALUES($1,$2,$3,$4,'historical:reconciliation_failed:safe-category',$5,$6,11,$7,'old-owner','old-token',$7,$7,$7,$8,'{"completed":false,"cursor":"private-checkpoint"}')`, env, nonce+"-"+string(rune('a'+seq)), gen, did, trigger, requestStatus, at, nil)
	}
	first := nonce + "-b"
	execute(`INSERT INTO appview_repository_recovery_records(environment,source_generation,recovery_key,request_id,uri) VALUES('prod',$1,'recovery-fixture',$2,'at://did:plc:fixture/site.standard.document/retained')`, gen, first)
	execute(`INSERT INTO appview_jetstream_checkpoints(environment,source_generation,source_host,stream_nsid,filter_fingerprint,cursor_kind,last_staged_seq,last_applied_seq,updated_at) VALUES('prod',$1,'fixture','fixture','fixture','jetstream_v2_seq',500,100,$2)`, gen, at)

	readEvidence := func() string {
		t.Helper()
		var value string
		if err := db.QueryRow(`SELECT json_build_object(
 'inbox',(SELECT json_agg(row_to_json(i) ORDER BY i.environment,i.seq) FROM appview_ingestion_inbox i WHERE source_generation=$1),
 'recovery',(SELECT json_agg(row_to_json(r) ORDER BY r.uri) FROM appview_repository_recovery_records r WHERE source_generation=$1),
 'checkpoint',(SELECT json_agg(row_to_json(c)) FROM appview_jetstream_checkpoints c WHERE source_generation=$1))::text`, gen).Scan(&value); err != nil {
			t.Fatal(err)
		}
		return value
	}
	before := readEvidence()
	readRequests := func(excludeSelected bool) string {
		t.Helper()
		var value string
		if err := db.QueryRow(`SELECT COALESCE(json_agg(row_to_json(r) ORDER BY r.environment,r.id)::text,'[]') FROM appview_ingestion_reconciliation_requests r WHERE source_generation=$1 AND (NOT $2 OR id<>ALL($3::text[]))`, gen, excludeSelected, []string{first, nonce + "-c"}).Scan(&value); err != nil {
			t.Fatal(err)
		}
		return value
	}
	allRequestsBefore := readRequests(false)
	unselectedBefore := readRequests(true)
	store := InboxStore{DB: db}
	for _, expected := range []int{1, 3} {
		if count, err := store.OperatorRetryFailedReconciliations(ctx, "prod", gen, expected, at.Add(time.Minute)); count != 0 || !errors.Is(err, ErrReconciliationRetryCount) {
			t.Fatal("mismatched count did not roll back", count, err)
		}
	}
	if readRequests(false) != allRequestsBefore {
		t.Fatal("count mismatch changed request state before rolling back")
	}
	if _, err := store.OperatorRetryFailedReconciliations(ctx, "prod", gen+"-different", 2, at); !errors.Is(err, ErrReconciliationRetryCount) {
		t.Fatal("different generation accepted", err)
	}
	// Holding one exact candidate must block the operation instead of skipping
	// it and treating a partial selection as an authorized retry.
	lock, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Rollback()
	if _, err := lock.Exec(`SELECT id FROM appview_ingestion_reconciliation_requests WHERE environment='prod' AND id=$1 FOR UPDATE`, first); err != nil {
		t.Fatal(err)
	}
	wait, cancel := context.WithTimeout(ctx, 50*time.Millisecond)
	_, retryErr := store.OperatorRetryFailedReconciliations(wait, "prod", gen, 2, at)
	cancel()
	if retryErr == nil || errors.Is(retryErr, ErrReconciliationRetryCount) {
		t.Fatal("retry skipped a locked candidate instead of respecting cancellation", retryErr)
	}
	if err := lock.Rollback(); err != nil {
		t.Fatal(err)
	}
	if readRequests(false) != allRequestsBefore {
		t.Fatal("cancelled retry changed request state")
	}
	if count, err := store.OperatorRetryFailedReconciliations(ctx, "prod", gen, 2, at.Add(time.Minute)); err != nil || count != 2 {
		t.Fatal("exact retry", count, err)
	}
	if after := readEvidence(); after != before {
		t.Fatal("operator retry altered terminal/checkpoint/recovery-record evidence")
	}
	if readRequests(true) != unselectedBefore {
		t.Fatal("retry changed an unselected or differently scoped request")
	}
	var valid int
	if err := db.QueryRow(`SELECT count(*) FROM appview_ingestion_reconciliation_requests WHERE environment='prod' AND source_generation=$1 AND id=ANY($2::text[]) AND status='pending' AND attempt_count=11 AND reason='historical:reconciliation_failed:safe-category' AND recovery_state='{"completed":false,"cursor":"private-checkpoint"}' AND completed_at IS NULL AND lease_owner IS NULL AND lease_token IS NULL AND lease_expires_at IS NULL AND next_attempt_at=$3 AND updated_at=$3`, gen, []string{first, nonce + "-c"}, at.Add(time.Minute)).Scan(&valid); err != nil || valid != 2 {
		t.Fatal("retry did not preserve historical state or clear leases", valid, err)
	}
	if _, err := store.OperatorRetryFailedReconciliations(ctx, "prod", gen, 2, at); !errors.Is(err, ErrReconciliationRetryCount) {
		t.Fatal("repeated retry changed already pending requests", err)
	}
	if _, err := store.OperatorRetryFailedReconciliations(ctx, "dev", gen, 2, at); !errors.Is(err, ErrReconciliationRetryCount) {
		t.Fatal("other environment accepted wrong expected count", err)
	}
}
