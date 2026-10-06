package operationscore

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// This suite requires a disposable database; it never reads DATABASE_URL.
func leaseDatabase(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set SOCIALWIRE_GO_TEST_DATABASE_URL to a disposable PostgreSQL database")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"20260830190000_add_fenced_role_leases.sql", "20260914004000_protect_shared_role_lease_fences.sql"} {
		data, err := os.ReadFile(filepath.Join("..", "..", "..", "database", "migrations", name))
		if err != nil {
			t.Fatal(err)
		}
		tx, err := db.BeginTx(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		// The test database is fresh, and the second migration's index may have
		// already been installed by another test in this suite.
		if name == "20260914004000_protect_shared_role_lease_fences.sql" {
			var exists bool
			if err := tx.QueryRowContext(ctx, "SELECT to_regclass('public.operations_role_leases_authority_key') IS NOT NULL").Scan(&exists); err != nil {
				t.Fatal(err)
			}
			if exists {
				_ = tx.Rollback()
				continue
			}
		}
		if _, err := tx.ExecContext(ctx, string(data)); err != nil {
			_ = tx.Rollback()
			t.Fatal(err)
		}
		if err := tx.Commit(); err != nil {
			t.Fatal(err)
		}
	}
	return db
}

func TestPostgresRoleLeaseTakeover(t *testing.T) {
	db := leaseDatabase(t)
	ctx := context.Background()
	store := PostgresRoleLeaseStore{db, "go-test"}
	role := "takeover-" + time.Now().Format("150405.000000000")
	lease, err := store.Acquire(ctx, role, "first", time.Minute)
	if err != nil || lease == nil {
		t.Fatalf("acquire: %v", err)
	}
	replacementLease, err := store.Acquire(ctx, role, "second", time.Minute)
	if err != nil || replacementLease != nil {
		t.Fatalf("standby got %v, %v", replacementLease, err)
	}
	same, err := store.Acquire(ctx, role, "first", time.Minute)
	if err != nil || same.FencingToken != lease.FencingToken {
		t.Fatal("live owner changed token", err)
	}
	if _, err := store.Renew(ctx, lease.RoleLeaseAuthority, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := store.Release(ctx, lease.RoleLeaseAuthority); err != nil {
		t.Fatal(err)
	}
	replacementLease, err = store.Acquire(ctx, role, "second", time.Minute)
	if err != nil || replacementLease == nil || replacementLease.FencingToken <= lease.FencingToken {
		t.Fatalf("takeover: %v %v", replacementLease, err)
	}
	if err := store.Validate(ctx, lease.RoleLeaseAuthority); !errors.Is(err, ErrLeaseConflict) {
		t.Fatalf("stale validation: %v", err)
	}
	if _, err := store.Renew(ctx, lease.RoleLeaseAuthority, time.Minute); !errors.Is(err, ErrLeaseConflict) {
		t.Fatalf("stale renewal: %v", err)
	}
	if err := store.Release(ctx, lease.RoleLeaseAuthority); !errors.Is(err, ErrLeaseConflict) {
		t.Fatalf("stale release: %v", err)
	}
	if err := store.Validate(ctx, replacementLease.RoleLeaseAuthority); err != nil {
		t.Fatal(err)
	}
}

func TestPostgresFenceChecksTimeAfterLock(t *testing.T) {
	db := leaseDatabase(t)
	ctx := context.Background()
	store := PostgresRoleLeaseStore{db, "go-test"}
	role := "wait-" + time.Now().Format("150405.000000000")
	lease, err := store.Acquire(ctx, role, "owner", 150*time.Millisecond)
	if err != nil || lease == nil {
		t.Fatal(err)
	}
	blocker, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Rollback()
	if _, err := blocker.ExecContext(ctx, "SELECT fencing_token FROM operations_role_leases WHERE environment=$1 AND role=$2 FOR UPDATE", store.Environment, role); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- store.Validate(ctx, lease.RoleLeaseAuthority) }()
	timer := time.NewTimer(200 * time.Millisecond)
	defer timer.Stop()
	<-timer.C
	if err := blocker.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := <-done; !errors.Is(err, ErrLeaseConflict) {
		t.Fatalf("expired owner passed fence after waiting: %v", err)
	}
}

func TestPostgresPublicationFenceAllowsRenewalBlocksRevocation(t *testing.T) {
	db := leaseDatabase(t)
	ctx := context.Background()
	store := PostgresRoleLeaseStore{db, "go-test"}
	role := "shared-" + time.Now().Format("150405.000000000")
	lease, err := store.Acquire(ctx, role, "owner", time.Minute)
	if err != nil || lease == nil {
		t.Fatal(err)
	}
	publication, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer publication.Rollback()
	if err := LockRoleLeaseFence(ctx, publication, lease.RoleLeaseAuthority, false); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Renew(ctx, lease.RoleLeaseAuthority, time.Minute); err != nil {
		t.Fatalf("shared fence blocked expiry-only renewal: %v", err)
	}
	if err := store.Release(ctx, lease.RoleLeaseAuthority); err == nil {
		t.Fatal("revocation crossed active publication fence")
	}
	if err := publication.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := store.Release(ctx, lease.RoleLeaseAuthority); err != nil {
		t.Fatal(err)
	}
}
