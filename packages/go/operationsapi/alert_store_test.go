package operationsapi

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5/pgxpool"
	"os"
	"testing"
	"time"
)

func TestAlertLifecycleDeliveryBudgetAndImmutableReplay(t *testing.T) {
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
	condition, _ := randomUUID()
	at := time.Now().UTC().Truncate(time.Microsecond)
	t.Cleanup(func() {
		c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for _, table := range []string{"operations_audit_events", "operations_idempotency_records"} {
			_, _ = pool.Exec(c, `DELETE FROM `+table+` WHERE environment='dev' AND target_id IN (SELECT id FROM operations_alerts WHERE environment='dev' AND condition_key=$1)`, condition)
		}
		_, _ = pool.Exec(c, `DELETE FROM operations_alerts WHERE environment='dev' AND condition_key=$1`, condition)
	})
	alert, err := store.OpenAlert(ctx, "fixture", condition, "warning", "Fixture", map[string]string{"token": "private", "count": "1"}, "fixture", at)
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := alert.Evidence["token"]; exists {
		t.Fatal("sensitive evidence retained")
	}
	updated, err := store.OpenAlert(ctx, "fixture", condition, "critical", "Updated", nil, "fixture", at)
	if err != nil || updated.ID != alert.ID || updated.Version != 1 {
		t.Fatal(updated, err)
	}
	failure := "transport_failure"
	for attempt := 1; attempt <= 8; attempt++ {
		if err = store.RecordAlertDelivery(ctx, alert.ID, &failure, at); err != nil {
			t.Fatal(err)
		}
		current, e := store.FetchAlert(ctx, alert.ID)
		if e != nil || current.DeliveryAttempts != attempt {
			t.Fatal(current, e)
		}
		if attempt < 8 && (current.NextDeliveryAt == nil || current.DeliveryDeadLetteredAt != nil) {
			t.Fatal("premature delivery exhaustion", current)
		}
		if attempt == 8 && (current.NextDeliveryAt != nil || current.DeliveryDeadLetteredAt == nil) {
			t.Fatal("delivery budget not enforced", current)
		}
	}
	pending, err := store.ListAlertsPendingDelivery(ctx, 100, at.Add(24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range pending {
		if a.ID == alert.ID {
			t.Fatal("dead letter selected for delivery")
		}
	}
	retried, err := store.RetryAlertDelivery(ctx, alert.ID, 9, "did:plc:fixture", "retry-"+condition, nil, nil, at)
	if err != nil || retried.Version != 10 || retried.DeliveryAttempts != 0 || retried.DeliveryDeadLetteredAt != nil || retried.LastDeliveryError != nil {
		t.Fatal(retried, err)
	}
	acknowledged, err := store.TransitionAlert(ctx, alert.ID, "acknowledged", 10, "did:plc:fixture", "ack-"+condition, nil, nil, at)
	if err != nil || acknowledged.Version != 11 {
		t.Fatal(acknowledged, err)
	}
	replay, err := store.RetryAlertDelivery(ctx, alert.ID, 9, "did:plc:fixture", "retry-"+condition, nil, nil, at.Add(time.Hour))
	if err != nil || replay.Version != 10 || replay.Status != "open" {
		t.Fatal("replay returned mutable current state", replay, err)
	}
	note := "changed"
	if _, err = store.RetryAlertDelivery(ctx, alert.ID, 9, "did:plc:fixture", "retry-"+condition, nil, &note, at); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatal("semantic key collision accepted", err)
	}
	resolved, err := store.TransitionAlert(ctx, alert.ID, "resolved", 11, "did:plc:fixture", "resolve-"+condition, nil, nil, at.Add(time.Hour))
	if err != nil || resolved.Version != 12 || resolved.AcknowledgedByDID == nil || resolved.ResolvedByDID == nil {
		t.Fatal(resolved, err)
	}
	if _, err = store.RetryAlertDelivery(ctx, alert.ID, 12, "did:plc:fixture", "resolved-retry-"+condition, nil, nil, at); !errors.Is(err, ErrInvalidTransition) {
		t.Fatal("resolved alert requeued", err)
	}
	if err = store.RecordAlertDelivery(ctx, alert.ID, nil, at); err != nil {
		t.Fatal(err)
	}
	current, err := store.FetchAlert(ctx, alert.ID)
	if err != nil || current.Version != 12 {
		t.Fatal("resolved alert changed by late delivery", current, err)
	}
	var expiry time.Time
	if err = pool.QueryRow(ctx, `SELECT expires_at FROM operations_alerts WHERE environment='dev' AND id=$1`, alert.ID).Scan(&expiry); err != nil || !expiry.Equal(at.Add(time.Hour+365*24*time.Hour)) {
		t.Fatal(expiry, err)
	}
	fresh, err := store.OpenAlert(ctx, "fixture", condition, "warning", "New incident", nil, "fixture", at.Add(2*time.Hour))
	if err != nil || fresh.ID == alert.ID {
		t.Fatal("resolved incident reused", fresh, err)
	}
}

func TestAlertDeliveryDelayIsBoundedAndStable(t *testing.T) {
	for attempt := 1; attempt <= 20; attempt++ {
		a := AlertDeliveryDelay("fixture", attempt)
		if a != AlertDeliveryDelay("fixture", attempt) || a < 30*time.Second || a > time.Hour {
			t.Fatal(attempt, a)
		}
	}
}
