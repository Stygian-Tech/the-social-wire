package schemaready

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func TestDatabaseSelection(t *testing.T) {
	for _, tc := range []struct {
		name    string
		env     map[string]string
		local   bool
		want    string
		failure bool
	}{
		{"gateway local", map[string]string{"APP_ENV": "local", "DATABASE_URL": "ignored"}, true, "", false},
		{"gateway default local", nil, true, "", false},
		{"worker no db", map[string]string{"APP_ENV": "dev"}, false, "", true},
		{"worker local", map[string]string{"APP_ENV": "local"}, false, "", true},
		{"hosted no env", map[string]string{"RAILWAY_SERVICE_ID": "service"}, true, "", true},
		{"hosted local", map[string]string{"APP_ENV": "local", "RAILWAY_ENVIRONMENT_ID": "env"}, true, "", true},
		{"gateway whitespace dev", map[string]string{"APP_ENV": " dev ", "DATABASE_URL": "postgres://dev", "RAILWAY_ENVIRONMENT_ID": "env"}, true, "", true},
		{"gateway whitespace prod", map[string]string{"APP_ENV": " prod ", "DATABASE_URL": "postgres://prod", "RAILWAY_ENVIRONMENT_ID": "env"}, true, "", true},
		{"worker trimmed dev", map[string]string{"APP_ENV": " dev ", "DATABASE_URL": "postgres://dev"}, false, "postgres://dev", false},
		{"invalid env", map[string]string{"APP_ENV": "development"}, true, "", true},
		{"hosted dev", map[string]string{"APP_ENV": "dev", "DATABASE_URL": "postgres://dev"}, false, "postgres://dev", false},
		{"hosted prod", map[string]string{"APP_ENV": "prod", "DATABASE_URL": "postgres://prod"}, true, "postgres://prod", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := DatabaseURL(tc.env, tc.local)
			if (err != nil) != tc.failure || got != tc.want {
				t.Fatalf("got %q, %v", got, err)
			}
		})
	}
}

func TestManifestRequiresAllUniqueVersions(t *testing.T) {
	dir := t.TempDir()
	if _, err := Manifest(dir); err == nil {
		t.Fatal("empty manifest accepted")
	}
	for _, name := range []string{"20260926010000_first.sql", "20260926190000_second.sql"} {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	versions, err := Manifest(dir)
	if err != nil || !reflect.DeepEqual(versions, []string{"20260926010000", "20260926190000"}) {
		t.Fatalf("%v %v", versions, err)
	}
	if err := os.WriteFile(filepath.Join(dir, "20260926010000_duplicate.sql"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Manifest(dir); err == nil {
		t.Fatal("duplicate accepted")
	}
	if _, err := ReadManifest(filepath.Join(dir, "absent")); err == nil {
		t.Fatal("missing packaged manifest accepted")
	}
	if _, err := validateVersions([]string{"not-a-version"}); err == nil {
		t.Fatal("invalid version accepted")
	}
}

type fakeRow struct {
	missing int
	err     error
}

func (r fakeRow) Scan(values ...any) error {
	if r.err == nil {
		*values[0].(*int) = r.missing
	}
	return r.err
}

type fakeConnection struct {
	rows   []fakeRow
	calls  int
	closed bool
}

func (c *fakeConnection) QueryRow(_ context.Context, _ string, _ ...any) pgx.Row {
	index := min(c.calls, len(c.rows)-1)
	c.calls++
	return c.rows[index]
}
func (c *fakeConnection) Close(context.Context) error { c.closed = true; return nil }

func TestWaitRechecksAndClosesBeforeReturning(t *testing.T) {
	conn := &fakeConnection{rows: []fakeRow{{missing: 2}, {missing: 1}, {}}}
	calls := 0
	err := wait(context.Background(), func(context.Context) (connection, error) { calls++; return conn, nil }, []string{"a", "b"}, quietLogger(), time.Millisecond)
	if err != nil || calls != 1 || conn.calls != 3 || !conn.closed {
		t.Fatalf("%v, connects=%d, polls=%d, closed=%v", err, calls, conn.calls, conn.closed)
	}
}

func TestWaitMissingOrInterruptedMigrationTimesOut(t *testing.T) {
	for _, row := range []fakeRow{{missing: 1}, {err: &pgconn.PgError{Code: "42P01"}}} {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
		conn := &fakeConnection{rows: []fakeRow{row}}
		err := wait(ctx, func(context.Context) (connection, error) { return conn, nil }, []string{"a"}, quietLogger(), time.Millisecond)
		cancel()
		if err == nil || !conn.closed {
			t.Fatal("unready ledger did not fail closed")
		}
	}
}

func TestWaitCancellationAndCredentialRedaction(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	var output bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&output, nil))
	err := wait(ctx, func(context.Context) (connection, error) {
		cancel()
		return nil, errors.New("postgres://user:secret-password@host/db")
	}, []string{"a"}, logger, time.Hour)
	if err == nil || strings.Contains(output.String()+err.Error(), "secret-password") {
		t.Fatalf("unsafe result: %v %s", err, output.String())
	}
	if err := Wait(context.Background(), "postgres://%invalid:secret-password", []string{"a"}, logger); err == nil || strings.Contains(err.Error(), "secret-password") {
		t.Fatal("invalid DSN leaked or accepted")
	}
}

func TestWaitPermissionFailureDoesNotRetry(t *testing.T) {
	conn := &fakeConnection{rows: []fakeRow{{err: &pgconn.PgError{Code: "42501", Message: "sensitive detail"}}}}
	err := wait(context.Background(), func(context.Context) (connection, error) { return conn, nil }, []string{"a"}, quietLogger(), time.Hour)
	if err == nil || conn.calls != 1 || !conn.closed || strings.Contains(err.Error(), "sensitive") {
		t.Fatal("permission failure must be immediate and redacted")
	}
}
