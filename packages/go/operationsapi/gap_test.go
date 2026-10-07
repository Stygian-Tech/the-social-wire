package operationsapi

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5/pgxpool"
	"os"
	"sync"
	"testing"
	"time"
)

func TestGapLifecycleIsVersionedAuditedAndIdempotent(t *testing.T) {
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
	id, err := randomUUID()
	if err != nil {
		t.Fatal(err)
	}
	key := "gap-fixture-" + id
	at := time.Now().UTC().Truncate(time.Millisecond)
	_, err = pool.Exec(ctx, `INSERT INTO appview_ingestion_gaps(environment,id,source,reason,status,collections,detected_at,updated_at,version) VALUES('dev',$1,'fixture','fixture','suspected','["site.standard.document"]'::jsonb,$2,$2,0)`, id, at)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for _, table := range []string{"operations_audit_events", "operations_idempotency_records"} {
			_, _ = pool.Exec(cleanup, `DELETE FROM `+table+` WHERE environment='dev' AND target_type='gap' AND target_id=$1`, id)
		}
		_, _ = pool.Exec(cleanup, `DELETE FROM appview_ingestion_gaps WHERE environment='dev' AND id=$1`, id)
	})
	var results [2]Gap
	var failures [2]error
	var group sync.WaitGroup
	for i := range 2 {
		group.Add(1)
		go func(i int) {
			defer group.Done()
			results[i], failures[i] = store.TransitionGap(ctx, id, "confirmed", 0, "did:plc:fixture", key, nil, nil, at.Add(time.Second))
		}(i)
	}
	group.Wait()
	for i := range 2 {
		if failures[i] != nil || results[i].Status != "confirmed" || results[i].Version != 1 || results[i].DetectedAt.Sub(at).Abs() > time.Microsecond {
			t.Fatal(results[i], failures[i])
		}
	}
	var count int
	err = pool.QueryRow(ctx, `SELECT count(*) FROM operations_audit_events WHERE environment='dev' AND target_id=$1 AND outcome IN ('succeeded','idempotent_replay')`, id).Scan(&count)
	if err != nil || count != 2 {
		t.Fatal("missing success/replay audit", count, err)
	}
	changedNote := "changed"
	if _, err = store.TransitionGap(ctx, id, "confirmed", 0, "did:plc:fixture", key, nil, &changedNote, at); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatal("semantic request reuse accepted", err)
	}
	if _, err = store.TransitionGap(ctx, id, "ignored", 0, "did:plc:fixture", key+"-stale", nil, nil, at); !errors.Is(err, ErrVersionConflict) {
		t.Fatal("stale version accepted", err)
	}
	if _, err = store.TransitionGap(ctx, id, "resolved", 1, "did:plc:fixture", key+"-invalid", nil, nil, at); !errors.Is(err, ErrInvalidTransition) {
		t.Fatal("invalid transition accepted", err)
	}
	terminal := at.Add(2 * time.Second)
	ignored, err := store.TransitionGap(ctx, id, "ignored", 1, "did:plc:fixture", key+"-ignore", nil, nil, terminal)
	if err != nil || ignored.Version != 2 {
		t.Fatal(ignored, err)
	}
	var expiry time.Time
	err = pool.QueryRow(ctx, `SELECT expires_at FROM operations_idempotency_records WHERE environment='dev' AND idempotency_key=$1`, key).Scan(&expiry)
	if err != nil || !expiry.Equal(terminal.Add(365*24*time.Hour)) {
		t.Fatal("lifecycle retention not extended", expiry, err)
	}
	history, err := store.ListGaps(ctx, "history", 250, nil)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, gap := range history.Items {
		found = found || gap.ID == id
	}
	if !found {
		t.Fatal("terminal gap absent from history")
	}
	active, err := store.ListGaps(ctx, "active", 250, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, gap := range active.Items {
		if gap.ID == id {
			t.Fatal("terminal gap remained active")
		}
	}
	malformed := "invalid"
	if _, err = store.ListGaps(ctx, "all", 250, &malformed); !errors.Is(err, ErrInvalidPaginationCursor) {
		t.Fatal("bad cursor silently restarted", err)
	}
	// A retry still returns the originally committed immutable snapshot, even after
	// a later terminal transition changed the current row.
	old, err := store.TransitionGap(ctx, id, "confirmed", 0, "did:plc:fixture", key, nil, nil, terminal)
	if err != nil || old.Status != "confirmed" || old.Version != 1 {
		t.Fatal("immutable replay drift", old, err)
	}
}
func TestIdempotencyFingerprintUsesUTF8LengthsAndSortedFields(t *testing.T) {
	id := "fixture"
	version := 3
	a, b := "one|two", "世界"
	first := IdempotencyFingerprint("gap.confirmed", "gap", &id, &version, map[string]*string{"a": &a, "b": &b})
	second := IdempotencyFingerprint("gap.confirmed", "gap", &id, &version, map[string]*string{"b": &b, "a": &a})
	if first != second || len(first) != 64 {
		t.Fatal("unstable fingerprint")
	}
	changed := "one"
	if first == IdempotencyFingerprint("gap.confirmed", "gap", &id, &version, map[string]*string{"a": &changed, "b": &b}) {
		t.Fatal("semantic difference ignored")
	}
	empty := ""
	if IdempotencyFingerprint("x", "gap", nil, nil, map[string]*string{"note": nil}) == IdempotencyFingerprint("x", "gap", nil, nil, map[string]*string{"note": &empty}) {
		t.Fatal("nil and empty collided")
	}
}
