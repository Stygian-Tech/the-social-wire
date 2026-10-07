package operationsapi

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPostgresDurableAuditAndOrderedChangeLog(t *testing.T) {
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
	defer pool.Close()
	store, err := NewPostgresStore(pool, "dev")
	if err != nil {
		t.Fatal(err)
	}
	fixture, err := randomUUID()
	if err != nil {
		t.Fatal(err)
	}
	entity := "operations-go-test-" + fixture
	t.Cleanup(func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM operations_change_events WHERE environment IN ('dev','prod') AND entity_id=$1`, entity)
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM operations_audit_events WHERE environment='dev' AND target_id=$1`, entity)
	})
	baseline, err := store.ChangeEventCursorBounds(ctx)
	if err != nil {
		t.Fatal(err)
	}
	first, err := store.AppendChangeEvent(ctx, ChangeEvent{EntityID: &entity, EventType: "fixture.created", EntityType: "fixture", Payload: map[string]string{"status": "initial"}, OccurredAt: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.AppendChangeEvent(ctx, ChangeEvent{EntityID: &entity, EventType: "fixture.changed", EntityType: "fixture", Payload: map[string]string{"status": "changed"}, OccurredAt: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	if first.Cursor != baseline.Latest+1 || second.Cursor != first.Cursor+1 {
		t.Fatal("noncontiguous durable ordering", baseline, first, second)
	}
	events, err := store.ListChangeEvents(ctx, baseline.Latest, 1)
	if err != nil || len(events) != 1 || events[0].Cursor != first.Cursor || events[0].Payload["status"] != "initial" {
		t.Fatal(events, err)
	}
	events, err = store.ListChangeEvents(ctx, first.Cursor, 10)
	if err != nil || len(events) != 1 || events[0].Cursor != second.Cursor {
		t.Fatal(events, err)
	}
	prod, err := NewPostgresStore(pool, "prod")
	if err != nil {
		t.Fatal(err)
	}
	foreign, err := prod.ListChangeEvents(ctx, 0, 500)
	if err != nil {
		t.Fatal(err)
	}
	for _, event := range foreign {
		if event.EntityID != nil && *event.EntityID == entity {
			t.Fatal("environment leak")
		}
	}
	expected := 7
	note := strings.Repeat("n", 300)
	audit := MutationAudit{OperatorDID: "did:plc:fixture", RequestID: "request-fixture", Action: "fixture.change", TargetType: "fixture", TargetID: &entity, ExpectedVersion: &expected, Note: &note, Before: map[string]string{"status": "initial"}, After: map[string]string{"httpStatus": "409"}, Outcome: "rejected", OccurredAt: time.Now()}
	if err = store.RecordAudit(ctx, audit); err != nil {
		t.Fatal(err)
	}
	var beforeText, noteText, outcome string
	var expires, occurred time.Time
	err = pool.QueryRow(ctx, `SELECT before_state::text,note,outcome,occurred_at,expires_at FROM operations_audit_events WHERE environment='dev' AND target_id=$1`, entity).Scan(&beforeText, &noteText, &outcome, &occurred, &expires)
	if err != nil {
		t.Fatal(err)
	}
	var before map[string]string
	if json.Unmarshal([]byte(beforeText), &before) != nil || before["expectedVersion"] != "7" || outcome != "rejected" || len(noteText) != 280 || expires.Sub(occurred) != 365*24*time.Hour {
		t.Fatal(before, noteText, outcome, expires.Sub(occurred))
	}
	// The store can use an existing transaction so future successful mutations,
	// their audit, and their event are committed or rolled back together.
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	transaction, err := NewPostgresStore(tx, "dev")
	if err != nil {
		t.Fatal(err)
	}
	audit.Action = "fixture.rollback"
	if err = transaction.RecordAudit(ctx, audit); err != nil {
		t.Fatal(err)
	}
	if _, err = transaction.AppendChangeEvent(ctx, ChangeEvent{EntityID: &entity, EventType: "fixture.rollback", EntityType: "fixture", OccurredAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err = tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	var count int
	err = pool.QueryRow(ctx, `SELECT count(*) FROM operations_audit_events WHERE environment='dev' AND target_id=$1 AND action='fixture.rollback'`, entity).Scan(&count)
	if err != nil || count != 0 {
		t.Fatal("audit escaped rollback", count, err)
	}
	bounds, err := store.ChangeEventCursorBounds(ctx)
	if err != nil || bounds.Latest != second.Cursor {
		t.Fatal("change event escaped rollback", bounds, err)
	}
}

func TestPostgresServiceEvidenceRevalidatesDurableCoordinatorFence(t *testing.T) {
	url := os.Getenv("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	// Rollback keeps these authority fixtures entirely local to this test.
	_, err = tx.Exec(ctx, `INSERT INTO operations_role_leases(environment,role,owner_id,fencing_token,acquired_at,lease_expires_at,updated_at) VALUES('dev','indexing.appview-coordinator','fixture-owner',19,clock_timestamp()-interval '2 minutes',clock_timestamp()+interval '1 minute',clock_timestamp())`)
	if err != nil {
		t.Fatal(err)
	}
	instance, err := randomUUID()
	if err != nil {
		t.Fatal(err)
	}
	_, err = tx.Exec(ctx, `INSERT INTO operations_service_state(service,environment,instance_id,liveness,readiness,freshness,completeness,dependency_state,started_at,heartbeat_at) VALUES('coordinator-appview','dev',$1,'healthy','healthy','healthy','healthy','{"coordinator_authority":"active","coordinator_owner_id":"fixture-owner","coordinator_fencing_token":"19","coordinator_role":"indexing.appview-coordinator"}'::jsonb,clock_timestamp(),clock_timestamp())`, instance)
	if err != nil {
		t.Fatal(err)
	}
	store, err := NewPostgresStore(tx, "dev")
	if err != nil {
		t.Fatal(err)
	}
	assertAuthority := func(expected string) {
		t.Helper()
		states, err := store.ListServiceStates(ctx)
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, state := range states {
			if state.InstanceID == instance {
				found = true
				if state.DependencyState["coordinator_authority"] != expected {
					t.Fatal(state.DependencyState)
				}
			}
		}
		if !found {
			t.Fatal("missing fresh coordinator")
		}
	}
	assertAuthority("active")
	for _, query := range []string{`UPDATE operations_role_leases SET fencing_token=20 WHERE environment='dev' AND role='indexing.appview-coordinator'`, `UPDATE operations_role_leases SET fencing_token=19,owner_id='new-owner' WHERE environment='dev' AND role='indexing.appview-coordinator'`, `UPDATE operations_role_leases SET owner_id='fixture-owner',lease_expires_at=clock_timestamp()-interval '1 second' WHERE environment='dev' AND role='indexing.appview-coordinator'`, `UPDATE operations_role_leases SET lease_expires_at=clock_timestamp()+interval '1 minute',released_at=clock_timestamp() WHERE environment='dev' AND role='indexing.appview-coordinator'`} {
		if _, err = tx.Exec(ctx, query); err != nil {
			t.Fatal(err)
		}
		assertAuthority("inactive")
	}
}
