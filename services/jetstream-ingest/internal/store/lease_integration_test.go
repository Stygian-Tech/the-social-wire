package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"
)

func leaseIntegrationStore(t *testing.T) (*Postgres, string) {
	t.Helper()
	url := os.Getenv("JETSTREAM_INGEST_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("JETSTREAM_INGEST_TEST_DATABASE_URL is not set")
	}
	db, err := sql.Open("pgx", url)
	if err != nil {
		t.Fatal(err)
	}
	name := fmt.Sprintf("integration-lease-%d", time.Now().UnixNano())
	source := testSource()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = db.ExecContext(ctx, "DELETE FROM appview_ingestion_leases WHERE environment = $1 AND lease_name = $2", source.Environment, name)
		_ = db.Close()
	})
	return New(db, source), name
}

func TestPostgresLeaseContenderDoesNotWaitForLiveOwnerLock(t *testing.T) {
	store, name := leaseIntegrationStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	owner, err := store.AcquireLease(ctx, name, "owner", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	tx, err := store.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SELECT 1 FROM appview_ingestion_leases WHERE environment = $1 AND lease_name = $2 FOR UPDATE`, store.source.Environment, name); err != nil {
		t.Fatal(err)
	}
	// Retain the owner's row lock: a known loser must reject via MVCC instead of queueing.
	contenderCtx, stop := context.WithTimeout(ctx, 500*time.Millisecond)
	defer stop()
	if _, err := store.AcquireLease(contenderCtx, name, "contender", time.Minute); !errors.Is(err, ErrLeaseUnavailable) {
		t.Fatalf("contender waited for the owner lock: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RenewLease(ctx, owner, time.Minute); err != nil {
		t.Fatalf("contender invalidated owner's fence: %v", err)
	}
}

func TestPostgresLeaseAcquisitionPreservesOwnerReleaseAndExpiryFences(t *testing.T) {
	store, name := leaseIntegrationStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	first, err := store.AcquireLease(ctx, name, "first", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	sameOwner, err := store.AcquireLease(ctx, name, "first", time.Minute)
	if err != nil || sameOwner.FencingToken != first.FencingToken+1 {
		t.Fatalf("same-owner acquisition = %+v, %v", sameOwner, err)
	}
	if _, err := store.RenewLease(ctx, first, time.Minute); !errors.Is(err, ErrLeaseUnavailable) {
		t.Fatalf("old fencing token renewed: %v", err)
	}
	if err := store.ReleaseLease(ctx, sameOwner); err != nil {
		t.Fatal(err)
	}
	released, err := store.AcquireLease(ctx, name, "second", time.Minute)
	if err != nil || released.FencingToken != sameOwner.FencingToken+1 {
		t.Fatalf("released acquisition = %+v, %v", released, err)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE appview_ingestion_leases SET acquired_at = NOW() - INTERVAL '2 minutes', lease_expires_at = NOW() - INTERVAL '1 minute' WHERE environment = $1 AND lease_name = $2`, store.source.Environment, name); err != nil {
		t.Fatal(err)
	}
	expired, err := store.AcquireLease(ctx, name, "third", time.Minute)
	if err != nil || expired.FencingToken != released.FencingToken+1 {
		t.Fatalf("expired acquisition = %+v, %v", expired, err)
	}
	if _, err := store.RenewLease(ctx, released, time.Minute); !errors.Is(err, ErrLeaseUnavailable) {
		t.Fatalf("replaced owner renewed: %v", err)
	}
}

func TestPostgresLeaseConcurrentAcquisitionHasOneFencedWinner(t *testing.T) {
	store, name := leaseIntegrationStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	start := make(chan struct{})
	type outcome struct {
		lease Lease
		err   error
	}
	const contenders = 12
	results := make(chan outcome, contenders)
	for i := range contenders {
		go func() {
			<-start
			lease, err := store.AcquireLease(ctx, name, fmt.Sprintf("owner-%d", i), time.Minute)
			results <- outcome{lease, err}
		}()
	}
	close(start)
	var winner Lease
	wins := 0
	for range contenders {
		result := <-results
		if result.err == nil {
			wins++
			winner = result.lease
		} else if !errors.Is(result.err, ErrLeaseUnavailable) {
			t.Fatalf("unexpected acquisition error: %v", result.err)
		}
	}
	if wins != 1 || winner.FencingToken != 1 {
		t.Fatalf("got %d winners, final winner %+v", wins, winner)
	}
	if _, err := store.RenewLease(ctx, winner, time.Minute); err != nil {
		t.Fatalf("winner lost its fence: %v", err)
	}
}

func TestPostgresLeaseConcurrentInsertStillUsesAuthoritativeConflictGuard(t *testing.T) {
	store, name := leaseIntegrationStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	tx, err := store.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	// The contender's MVCC precheck cannot see this uncommitted acquisition.
	if _, err := tx.ExecContext(ctx, `INSERT INTO appview_ingestion_leases
		(environment, lease_name, source_generation, owner_id, fencing_token, acquired_at, lease_expires_at, updated_at)
		VALUES ($1, $2, $3, 'winner', 1, NOW(), NOW() + INTERVAL '1 minute', NOW())`,
		store.source.Environment, name, store.source.Generation); err != nil {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() {
		_, err := store.AcquireLease(ctx, name, "loser", time.Minute)
		result <- err
	}()
	// Establish the race at the unique-index wait instead of relying on scheduling.
	for {
		var waiting bool
		err := store.db.QueryRowContext(ctx, `SELECT EXISTS (
			SELECT 1 FROM pg_stat_activity WHERE datname = current_database()
			AND pid <> pg_backend_pid() AND wait_event_type = 'Lock'
			AND query LIKE '%INSERT INTO appview_ingestion_leases%')`).Scan(&waiting)
		if err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		select {
		case err := <-result:
			t.Fatalf("acquisition completed before conflicting transaction committed: %v", err)
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-time.After(5 * time.Millisecond):
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := <-result; !errors.Is(err, ErrLeaseUnavailable) {
		t.Fatalf("conflict guard allowed a second owner: %v", err)
	}
	winner := Lease{Name: name, OwnerID: "winner", FencingToken: 1}
	if _, err := store.RenewLease(ctx, winner, time.Minute); err != nil {
		t.Fatalf("concurrent insert replaced the original owner's fence: %v", err)
	}
}
