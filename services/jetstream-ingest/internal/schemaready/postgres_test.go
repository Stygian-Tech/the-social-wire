package schemaready

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestPostgresCommittedReceiptsGateStartup(t *testing.T) {
	databaseURL := os.Getenv("SCHEMA_READY_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("SCHEMA_READY_TEST_DATABASE_URL is not set")
	}
	ctx := context.Background()
	config, err := pgx.ParseConfig(databaseURL)
	if err != nil {
		t.Fatal("parse test database configuration")
	}
	if err := requireLoopbackTestConfig(config); err != nil {
		t.Fatal(err)
	}
	admin, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal("connect test database")
	}
	defer admin.Close(ctx)
	// Tests own a separate database: never modify the migrated integration schema.
	name := fmt.Sprintf("schema_ready_test_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{name}.Sanitize()); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := admin.Exec(ctx, "DROP DATABASE "+pgx.Identifier{name}.Sanitize()+" WITH (FORCE)"); err != nil {
			t.Error(err)
		}
	}()
	config = config.Copy()
	config.Database = name
	isolatedURL, err := url.Parse(databaseURL)
	if err != nil {
		t.Fatal("parse test database URL")
	}
	isolatedURL.Path = "/" + name
	testURL := isolatedURL.String()
	writer, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal("connect isolated database")
	}
	defer writer.Close(ctx)
	required := []string{"20260926010000", "20260926190000"}
	assertBlocked := func(label string) {
		t.Helper()
		waitCtx, cancel := context.WithTimeout(ctx, 250*time.Millisecond)
		defer cancel()
		var output strings.Builder
		if err := Wait(waitCtx, testURL, required, slog.New(slog.NewTextHandler(&output, nil))); err == nil {
			t.Fatalf("%s allowed startup", label)
		}
		state := "missing_receipts"
		if label == "missing ledger" {
			state = "missing_ledger"
		}
		if !strings.Contains(output.String(), state) {
			t.Fatalf("%s did not reach the ledger check: %s", label, output.String())
		}
	}
	assertBlocked("missing ledger")
	if _, err := writer.Exec(ctx, "CREATE TABLE public.schema_migrations(version text PRIMARY KEY); INSERT INTO public.schema_migrations VALUES ('20990101000000')"); err != nil {
		t.Fatal(err)
	}
	assertBlocked("newer receipt with missing historical migrations")
	tx, err := writer.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, "INSERT INTO public.schema_migrations SELECT unnest($1::text[])", required); err != nil {
		t.Fatal(err)
	}
	assertBlocked("uncommitted migration")
	if err := tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	assertBlocked("interrupted migration")
	if _, err := writer.Exec(ctx, "INSERT INTO public.schema_migrations SELECT unnest($1::text[])", required); err != nil {
		t.Fatal(err)
	}
	readyCtx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	if err := Wait(readyCtx, testURL, required, quietLogger()); err != nil {
		t.Fatal(err)
	}
	var connections int
	if err := writer.QueryRow(ctx, "SELECT count(*) FROM pg_stat_activity WHERE datname=$1 AND application_name='socialwire-schema-ready'", name).Scan(&connections); err != nil || connections != 0 {
		t.Fatalf("startup gate connection retained: count=%d, err=%v", connections, err)
	}
}

func requireLoopbackTestConfig(config *pgx.ConnConfig) error {
	local := func(host string) bool { return host == "localhost" || net.ParseIP(host).IsLoopback() }
	if !local(config.Host) {
		return fmt.Errorf("schema readiness integration tests require a loopback database")
	}
	for _, fallback := range config.Fallbacks {
		if !local(fallback.Host) {
			return fmt.Errorf("schema readiness integration tests require loopback fallback hosts")
		}
	}
	return nil
}

func TestPostgresIntegrationRejectsRemoteTargetsIncludingFallbacks(t *testing.T) {
	config, err := pgx.ParseConfig("postgres://localhost/test?sslmode=prefer")
	if err != nil {
		t.Fatal(err)
	}
	if err := requireLoopbackTestConfig(config); err != nil {
		t.Fatal(err)
	}
	config.Host = "database.example.invalid"
	if err := requireLoopbackTestConfig(config); err == nil {
		t.Fatal("accepted hosted database")
	}
	config.Host = "127.0.0.1"
	if len(config.Fallbacks) == 0 {
		t.Fatal("expected TLS fallback fixture")
	}
	config.Fallbacks[0].Host = "database.example.invalid"
	if err := requireLoopbackTestConfig(config); err == nil {
		t.Fatal("accepted hosted fallback database")
	}
}

func TestPostgresFailedConnectionIsBoundedAndRedacted(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
	defer cancel()
	err := Wait(ctx, "postgres://test:secret-password@127.0.0.1:1/test?sslmode=disable", []string{"20260926190000"}, quietLogger())
	if err == nil || strings.Contains(err.Error(), "secret-password") {
		t.Fatal("connection failure did not fail safely")
	}
}
