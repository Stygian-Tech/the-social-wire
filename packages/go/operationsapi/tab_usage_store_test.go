package operationsapi

import (
	"context"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/navigationcore"
	"os"
	"strings"
	"testing"
	"time"
)

func TestTabUsagePseudonymousWindowDedupIsolationAndRetention(t *testing.T) {
	url := os.Getenv("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	base, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer base.Close()
	id, _ := randomUUID()
	schema := "tab_fixture_" + strings.ReplaceAll(id, "-", "")
	if _, err = base.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer base.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE")
	if _, err = base.Exec(ctx, "CREATE TABLE "+schema+".operations_tab_activity (LIKE public.operations_tab_activity INCLUDING ALL)"); err != nil {
		t.Fatal(err)
	}
	conf, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	conf.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, conf)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()
	store, _ := NewPostgresStore(pool, "dev")
	at := time.Date(2031, 3, 8, 12, 0, 0, 0, time.UTC)
	secret := strings.Repeat("s", 32)
	add := func(did, tab string, age int, environment string) {
		t.Helper()
		if err := navigationcore.Record(ctx, db, secret, environment, did, tab, "tab_open", 0, at.AddDate(0, 0, -age)); err != nil {
			t.Fatal(err)
		}
	}
	add("did:plc:one", "home", 0, "dev")
	add("did:plc:one", "messages", 0, "dev")
	add("did:plc:one", "home", 0, "dev")
	add("did:plc:two", "home", 6, "dev")
	add("did:plc:three", "messages", 29, "dev")
	add("did:plc:expired", "home", 30, "dev")
	add("did:plc:production", "home", 0, "prod")
	add("did:plc:local", "explore", 0, "local")
	if err = navigationcore.Record(ctx, db, secret, "dev", "did:plc:one", "home", "tab_dwell", 30000, at); err != nil {
		t.Fatal(err)
	}
	summary, err := store.FetchTabUsage(ctx, at)
	if err != nil || summary.DAU != 1 || summary.WAU != 2 || summary.MAU != 3 || len(summary.Tabs) != 2 {
		t.Fatal(summary, err)
	}
	if summary.Tabs[0].Tab != "home" || summary.Tabs[0].Opens != 3 || summary.Tabs[0].DwellMS != 30000 {
		t.Fatal(summary.Tabs)
	}
	store.TabUsageEnvironment = "local"
	local, localErr := store.FetchTabUsage(ctx, at)
	if localErr != nil || local.SourceEnvironment != "local" || local.MAU != 1 || local.Tabs[0].Tab != "explore" {
		t.Fatal(local, localErr)
	}
	store.TabUsageEnvironment = ""
	var rawKeys string
	if err = pool.QueryRow(ctx, `SELECT string_agg(viewer_key,',') FROM operations_tab_activity`).Scan(&rawKeys); err != nil || strings.Contains(rawKeys, "did:") {
		t.Fatal(rawKeys, err)
	}
	if err = store.PruneTabUsage(ctx, at); err != nil {
		t.Fatal(err)
	}
	var remaining int
	if err = pool.QueryRow(ctx, `SELECT count(*) FROM operations_tab_activity WHERE activity_day<($1::timestamptz AT TIME ZONE 'UTC')::date-29`, at).Scan(&remaining); err != nil || remaining != 0 {
		t.Fatal(remaining, err)
	}
	prod, _ := NewPostgresStore(pool, "prod")
	other, err := prod.FetchTabUsage(ctx, at)
	if err != nil || other.MAU != 1 {
		t.Fatal(other, err)
	}
}
