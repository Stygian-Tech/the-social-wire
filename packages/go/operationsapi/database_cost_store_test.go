package operationsapi

import (
	"context"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"os"
	"sync"
	"testing"
	"time"
)

type collectingTelemetry struct {
	mu      sync.Mutex
	samples []telemetrycore.MetricSample
}

func (c *collectingTelemetry) Export(_ context.Context, samples []telemetrycore.MetricSample) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.samples = append(c.samples, samples...)
	return nil
}
func TestDatabaseObservabilityUsesOldestEvidenceAndResetsRates(t *testing.T) {
	observations := DatabaseObservations{}
	at := time.Now().UTC()
	if observations.Snapshot(at) != nil {
		t.Fatal("unavailable database became zero")
	}
	observations.RecordCounters(databaseCounterSample{connections: 2, maxConnections: 100, transactions: 100, at: at})
	if observations.Snapshot(at) != nil {
		t.Fatal("partial evidence became complete")
	}
	observations.RecordTables(databaseTableSample{size: 200, records: 3, topTables: []DatabaseTableRecordCount{}, at: at.Add(-15 * time.Minute)})
	observations.RecordCounters(databaseCounterSample{connections: 3, maxConnections: 100, transactions: 200, at: at.Add(10 * time.Second)})
	snapshot := observations.Snapshot(at.Add(10 * time.Second))
	if snapshot.ObservedAt.Time != at.Add(-15*time.Minute) || snapshot.EvidenceAgeSeconds != 910 || snapshot.TransactionRatePerSecond == nil || *snapshot.TransactionRatePerSecond != 10 {
		t.Fatal(snapshot)
	}
	observations.RecordCounters(databaseCounterSample{transactions: 1, at: at.Add(20 * time.Second)})
	if observations.Snapshot(at).TransactionRatePerSecond != nil {
		t.Fatal("counter reset emitted negative rate")
	}
	observations.RecordCounters(databaseCounterSample{transactions: 10, statsResetAt: pointer(at), at: at.Add(30 * time.Second)})
	if observations.Snapshot(at).TransactionRatePerSecond != nil {
		t.Fatal("stats reset reused rate")
	}
}
func TestDatabaseCostReadsAndExpiryBounds(t *testing.T) {
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
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	store, _ := NewPostgresStore(tx, "dev")
	exporter := &collectingTelemetry{}
	store.TelemetryExporter = exporter
	at := time.Now().UTC().Truncate(time.Microsecond)
	fixture, _ := randomUUID()
	if err = store.recordDatabaseObservabilityCounters(ctx, at); err != nil {
		t.Fatal(err)
	}
	if err = store.recordDatabaseObservabilityTables(ctx, at.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	observed := store.FetchDatabaseObservability(ctx, at)
	if observed == nil || observed.DatabaseSizeBytes <= 0 || observed.MaxConnections <= 0 || observed.ObservedAt.Time != at.Add(-time.Minute) {
		t.Fatal(observed)
	}
	if _, err = tx.Exec(ctx, `DELETE FROM appview_ingestion_inbox WHERE environment='dev'`); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO appview_ingestion_inbox(environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,payload,event_time,status,expires_at) SELECT 'dev',$1,i,'fixture.invalid','jetstream_v2_seq','sync','did:plc:fixture','{}'::jsonb,$2,'pending',$2 FROM generate_series(1,1002) i`, fixture, at.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	count, truncated, err := store.databaseExpiryBacklog(ctx, "appview_ingestion_inbox", at, 1000)
	if err != nil || count != 0 || !truncated {
		t.Fatal("protected rows distorted lower bound", count, truncated, err)
	}
	if _, _, err = store.databaseExpiryBacklog(ctx, "untrusted;drop table", at, 1000); err == nil {
		t.Fatal("untrusted table accepted")
	}
	if err = store.RecordDatabaseCostTelemetry(ctx, "tables", at); err != nil {
		t.Fatal(err)
	}
	exporter.mu.Lock()
	first := len(exporter.samples)
	exporter.mu.Unlock()
	if first == 0 {
		t.Fatal("table collector emitted no samples")
	}
	if err = store.RecordDatabaseCostTelemetry(ctx, "tables", at.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	exporter.mu.Lock()
	defer exporter.mu.Unlock()
	if len(exporter.samples) != first {
		t.Fatal("collector throttle refreshed samples early")
	}
	for _, sample := range exporter.samples {
		if sample.Dimensions["environment"] != "dev" || sample.Dimensions["service"] != "postgres" || !sample.At.Equal(at) {
			t.Fatal(sample)
		}
	}
}
