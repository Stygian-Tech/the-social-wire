package gateway

import (
	"context"
	"database/sql"
	"encoding/json"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"os"
	"strings"
	"testing"
	"time"
)

func fixtureDB(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("canonical disposable PostgreSQL fixture not configured")
	}
	db, e := sql.Open("pgx", dsn)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close() })
	return db
}
func TestCanonicalPGRecordCacheAndTelemetry(t *testing.T) {
	db := fixtureDB(t)
	ctx := context.Background()
	did := "did:plc:gatewayconformance"
	cache := RecordCache{DB: db, Backend: "postgres"}
	cid := "fixture"
	v := RecordSnapshot{CID: &cid, JSONBody: `{"uri":"at://did:plc:gatewayconformance/c/k","value":{"name":"Fixture"}}`, CachedAt: float64(time.Now().UnixMilli())}
	t.Cleanup(func() {
		db.ExecContext(ctx, `DELETE FROM pds_repo_record_cache WHERE owner_did=$1`, did)
		db.ExecContext(ctx, `DELETE FROM operations_metric_rollups WHERE environment='dev' AND metric_name='gateway.fixture'`)
	})
	if e := cache.Put(ctx, did, "c:k", v); e != nil {
		t.Fatal(e)
	}
	got, e := cache.Get(ctx, did, "c:k")
	if e != nil || got == nil || got.CID == nil || *got.CID != cid {
		t.Fatal(got, e)
	}
	if other, e := cache.Get(ctx, "did:plc:other", "c:k"); e != nil || other != nil {
		t.Fatal("viewer cache collision")
	}
	_, e = db.ExecContext(ctx, `UPDATE pds_repo_record_cache SET expires_at=clock_timestamp()-interval '1 second' WHERE owner_did=$1`, did)
	if e != nil {
		t.Fatal(e)
	}
	if expired, e := cache.Get(ctx, did, "c:k"); e != nil || expired != nil {
		t.Fatal("hard expiry ignored")
	}
	exporter := telemetrycore.PostgresExporter{DB: db, Environment: "dev"}
	at := time.Now().Truncate(time.Minute)
	samples := []telemetrycore.MetricSample{{Name: "gateway.fixture", Value: 1, At: at, Dimensions: map[string]string{"environment": "dev", "event": "fixture", "authorization": "must-drop"}}, {Name: "gateway.fixture", Value: 3, At: at, Dimensions: map[string]string{"environment": "dev", "event": "fixture", "authorization": "must-drop"}}}
	if e := exporter.Export(ctx, samples); e != nil {
		t.Fatal(e)
	}
	var count int
	var sum, minimum, maximum float64
	var dims string
	if e := db.QueryRowContext(ctx, `SELECT sample_count,value_sum,value_min,value_max,dimensions::text FROM operations_metric_rollups WHERE environment='dev' AND metric_name='gateway.fixture' AND bucket_start=$1`, at).Scan(&count, &sum, &minimum, &maximum, &dims); e != nil {
		t.Fatal(e)
	}
	if count != 2 || sum != 4 || minimum != 1 || maximum != 3 || strings.Contains(dims, "authorization") {
		t.Fatal(count, sum, dims)
	}
	samples[0].Dimensions = map[string]string{"environment": "prod"}
	if e := exporter.Export(ctx, samples[:1]); e == nil {
		t.Fatal("cross environment export accepted")
	}
	var obj map[string]any
	if json.Unmarshal([]byte(dims), &obj) != nil {
		t.Fatal(dims)
	}
}
