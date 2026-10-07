package operationsapi

import (
	"context"
	"github.com/jackc/pgx/v5/pgxpool"
	"os"
	"testing"
	"time"
)

func TestTelemetryReadPaginationAndRetentionKeepsUnresolvedInbox(t *testing.T) {
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
	fixture, _ := randomUUID()
	at := time.Date(2030, 1, 1, 0, 0, 0, 0, time.UTC)
	for i, id := range []string{fixture + "a", fixture + "b", fixture + "c"} {
		env := "dev"
		if i == 2 {
			env = "prod"
		}
		if _, err = tx.Exec(ctx, `INSERT INTO operations_trace_spans(environment,id,trace_id,service,name,started_at,duration_ms,status,attributes,expires_at) VALUES($1,$2,$3,'fixture','fixture',$4,1.25,'ok','{"count":"1"}'::jsonb,$5)`, env, id, fixture, at, at.Add(time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	spans, err := store.ListTraceSpans(ctx, 10, &fixture)
	if err != nil || len(spans) != 2 || spans[0].Environment != "dev" {
		t.Fatal(spans, err)
	}
	page, err := store.ListTraceSpansPage(ctx, at, at, 1, nil)
	if err != nil || page.TotalCount != 2 || page.NextCursor == nil || page.Items[0].ID != fixture+"b" {
		t.Fatal(page, err)
	}
	next, err := store.ListTraceSpansPage(ctx, at, at, 1, page.NextCursor)
	if err != nil || len(next.Items) != 1 || next.Items[0].ID != fixture+"a" || next.NextCursor != nil {
		t.Fatal(next, err)
	}
	metric := "fixture-" + fixture
	collection := "site.standard.document"
	if _, err = tx.Exec(ctx, `INSERT INTO operations_metric_rollups(environment,bucket_start,metric_name,dimensions_hash,dimensions,sample_count,value_sum,value_min,value_max,histogram_buckets,expires_at) VALUES('dev',$1,$2,$3,'{"collection":"site.standard.document"}'::jsonb,2,7,3,4,'{}'::jsonb,$4)`, at, metric, fixture, at.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	rollups, err := store.ListMetricRollups(ctx, at, at, &metric, &collection, 100)
	if err != nil || len(rollups) != 1 || rollups[0].SampleCount != 2 || rollups[0].ValueSum != 7 {
		t.Fatal(rollups, err)
	}
	for i, name := range []string{"jetstream.disconnected", "unrelated.event"} {
		id := fixture + name
		if _, err = tx.Exec(ctx, `INSERT INTO operations_events(environment,id,service,instance_id,event_name,occurred_at,attributes,expires_at) VALUES('dev',$1,'fixture','fixture',$2,$3,'{}'::jsonb,$4)`, id, name, at.Add(time.Duration(i)*time.Second), at.Add(time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	events, err := store.ListGapInvestigationEvents(ctx, at, at.Add(time.Minute), 100)
	if err != nil || len(events) != 1 || events[0].Name != "jetstream.disconnected" {
		t.Fatal(events, err)
	}
	for seq, status := range []string{"pending", "dead_letter", "dead_letter", "applied"} {
		var applied, dead, reconciled *time.Time
		if status == "dead_letter" {
			dead = &at
		}
		if seq == 2 {
			reconciled = &at
		}
		if status == "applied" {
			applied = &at
		}
		if _, err = tx.Exec(ctx, `INSERT INTO appview_ingestion_inbox(environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,payload,event_time,status,applied_at,dead_lettered_at,reconciled_at,expires_at) VALUES('dev',$1,$2,'fixture.invalid','jetstream_v2_seq','sync','did:plc:fixture','{}'::jsonb,$3,$4,$5,$6,$7,$3)`, fixture, seq, at, status, applied, dead, reconciled); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = store.CleanupExpired(ctx, at.Add(2*time.Hour), 10000); err != nil {
		t.Fatal(err)
	}
	var kept []int64
	rows, err := tx.Query(ctx, `SELECT seq FROM appview_ingestion_inbox WHERE environment='dev' AND source_generation=$1 ORDER BY seq`, fixture)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var seq int64
		if err = rows.Scan(&seq); err != nil {
			t.Fatal(err)
		}
		kept = append(kept, seq)
	}
	err = rows.Err()
	rows.Close()
	if err != nil || len(kept) != 2 || kept[0] != 0 || kept[1] != 1 {
		t.Fatal("unresolved canonical work discarded", kept, err)
	}
	var prod int
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM operations_trace_spans WHERE environment='prod' AND trace_id=$1`, fixture).Scan(&prod); err != nil || prod != 1 {
		t.Fatal("retention crossed environment", prod, err)
	}
}
