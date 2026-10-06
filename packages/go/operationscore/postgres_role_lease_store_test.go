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
	s := PostgresRoleLeaseStore{db, "go-test"}
	role := "takeover-" + time.Now().Format("150405.000000000")
	a, err := s.Acquire(ctx, role, "first", time.Minute)
	if err != nil || a == nil {
		t.Fatalf("acquire: %v", err)
	}
	b, err := s.Acquire(ctx, role, "second", time.Minute)
	if err != nil || b != nil {
		t.Fatalf("standby got %v, %v", b, err)
	}
	same, err := s.Acquire(ctx, role, "first", time.Minute)
	if err != nil || same.FencingToken != a.FencingToken {
		t.Fatal("live owner changed token", err)
	}
	if _, err := s.Renew(ctx, a.RoleLeaseAuthority, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := s.Release(ctx, a.RoleLeaseAuthority); err != nil {
		t.Fatal(err)
	}
	b, err = s.Acquire(ctx, role, "second", time.Minute)
	if err != nil || b == nil || b.FencingToken <= a.FencingToken {
		t.Fatalf("takeover: %v %v", b, err)
	}
	if err := s.Validate(ctx, a.RoleLeaseAuthority); !errors.Is(err, ErrLeaseConflict) {
		t.Fatalf("stale validation: %v", err)
	}
	if _, err := s.Renew(ctx, a.RoleLeaseAuthority, time.Minute); !errors.Is(err, ErrLeaseConflict) {
		t.Fatalf("stale renewal: %v", err)
	}
	if err := s.Release(ctx, a.RoleLeaseAuthority); !errors.Is(err, ErrLeaseConflict) {
		t.Fatalf("stale release: %v", err)
	}
	if err := s.Validate(ctx, b.RoleLeaseAuthority); err != nil {
		t.Fatal(err)
	}
}

func TestPostgresFenceChecksTimeAfterLock(t *testing.T) {
	db := leaseDatabase(t)
	ctx := context.Background()
	s := PostgresRoleLeaseStore{db, "go-test"}
	role := "wait-" + time.Now().Format("150405.000000000")
	a, err := s.Acquire(ctx, role, "owner", 150*time.Millisecond)
	if err != nil || a == nil {
		t.Fatal(err)
	}
	blocker, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Rollback()
	if _, err := blocker.ExecContext(ctx, "SELECT fencing_token FROM operations_role_leases WHERE environment=$1 AND role=$2 FOR UPDATE", s.Environment, role); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- s.Validate(ctx, a.RoleLeaseAuthority) }()
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
	s := PostgresRoleLeaseStore{db, "go-test"}
	role := "shared-" + time.Now().Format("150405.000000000")
	a, err := s.Acquire(ctx, role, "owner", time.Minute)
	if err != nil || a == nil {
		t.Fatal(err)
	}
	publication, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer publication.Rollback()
	if err := LockRoleLeaseFence(ctx, publication, a.RoleLeaseAuthority, false); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Renew(ctx, a.RoleLeaseAuthority, time.Minute); err != nil {
		t.Fatalf("shared fence blocked expiry-only renewal: %v", err)
	}
	if err := s.Release(ctx, a.RoleLeaseAuthority); err == nil {
		t.Fatal("revocation crossed active publication fence")
	}
	if err := publication.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := s.Release(ctx, a.RoleLeaseAuthority); err != nil {
		t.Fatal(err)
	}
}
