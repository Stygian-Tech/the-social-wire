package store

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func TestWireCompactAdmissionIntegration(t *testing.T) {
	url := os.Getenv("JETSTREAM_INGEST_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("JETSTREAM_INGEST_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db, err := sql.Open("pgx", url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	key := fmt.Sprintf("compact-integration-%d", time.Now().UnixNano())
	if _, err := db.ExecContext(ctx, `INSERT INTO wire_items (canonical_key, canonical_url, source_domain, source_name, title, first_seen_at, last_seen_at, expires_at) VALUES ($1, $2, 'example.test', 'Integration', 'Integration', NOW(), NOW(), NOW()+INTERVAL '1 day')`, key, "https://example.test/"+key); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), "DELETE FROM wire_items WHERE canonical_key = $1", key)
	})
	alias := "at://did:plc:integration/app.bsky.feed.post/" + key
	expired := alias + "-expired"
	for _, value := range []struct{ key, interval string }{{alias, "1 day"}, {expired, "-1 day"}} {
		if _, err := db.ExecContext(ctx, `INSERT INTO wire_item_aliases(alias_key, canonical_key, alias_type, expires_at) VALUES ($1, $2, 'at_uri', NOW()+$3::interval)`, value.key, key, value.interval); err != nil {
			t.Fatal(err)
		}
	}

	// A concurrent alias change must not split the admission decision across key batches.
	snapshot, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead})
	if err != nil {
		t.Fatal(err)
	}
	expiredEvent := wireSignal("app.bsky.feed.like", "create", fmt.Sprintf(`{"uri":%q}`, expired))
	admitted, err := filterWireSignals(ctx, snapshot, []ingest.InboxEvent{expiredEvent})
	if err != nil || len(admitted) != 0 {
		snapshot.Rollback()
		t.Fatalf("initial expired admission: %v %v", admitted, err)
	}
	if _, err := db.ExecContext(ctx, "UPDATE wire_item_aliases SET expires_at = NOW()+INTERVAL '1 day' WHERE alias_key = $1", expired); err != nil {
		snapshot.Rollback()
		t.Fatal(err)
	}
	admitted, err = filterWireSignals(ctx, snapshot, []ingest.InboxEvent{expiredEvent})
	snapshot.Rollback()
	if err != nil || len(admitted) != 0 {
		t.Fatalf("snapshot changed mid-transaction: %v %v", admitted, err)
	}
	if _, err := db.ExecContext(ctx, "UPDATE wire_item_aliases SET expires_at = NOW()-INTERVAL '1 day' WHERE alias_key = $1", expired); err != nil {
		t.Fatal(err)
	}
	events := []ingest.InboxEvent{
		wireSignal("app.bsky.feed.like", "create", fmt.Sprintf(`{"uri":%q,"cid":"original"}`, alias)),
		wireSignal("app.bsky.feed.repost", "update", fmt.Sprintf(`{"uri":%q}`, alias)),
		wireSignal("app.bsky.feed.like", "create", fmt.Sprintf(`{"uri":%q}`, expired)),
		wireSignal("app.bsky.feed.like", "create", `{"uri":"at://missing"}`),
		wireSignal("app.bsky.feed.like", "create", fmt.Sprintf(`%q`, alias)),
		wireSignal("app.bsky.graph.follow", "create", `"did:plc:new-actor"`),
		wireSignal("app.bsky.feed.like", "delete", `null`),
		wireSignal("app.bsky.graph.follow", "delete", `null`),
		{Kind: "account", Payload: []byte(`{"kind":"account","account":{"active":false}}`)},
		wireSignal("app.bsky.feed.like", "create", `{"uri":false}`),
		wireSignal("app.bsky.feed.like", "create", `{"uri":null}`),
	}
	now := time.Now().UTC()
	for i := range events {
		events[i].Seq = uint64(i + 1)
		events[i].Time = now
		events[i].RepoDID = "did:plc:integration"
	}
	var original []uint64
	for _, enabled := range []bool{false, true} {
		source := wireTestSource()
		source.Generation = fmt.Sprintf("%s-%t", key, enabled)
		p := New(db, source)
		p.ConfigureWireCompactIngest(enabled)
		lease, err := p.AcquireLease(ctx, source.Generation, "integration-owner", time.Minute)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			cleanup := context.Background()
			result, err := db.ExecContext(cleanup, "DELETE FROM wire_ingestion_inbox WHERE environment = $1 AND source_generation = $2", source.Environment, source.Generation)
			if err == nil {
				count, _ := result.RowsAffected()
				_, _ = db.ExecContext(cleanup, "UPDATE wire_ingestion_admission SET retained_rows = retained_rows - $2 WHERE environment = $1", source.Environment, count)
			}
			for _, table := range []string{"appview_jetstream_checkpoints", "wire_ingestion_recovery_anchors"} {
				_, _ = db.ExecContext(cleanup, "DELETE FROM "+table+" WHERE environment = $1 AND source_generation = $2", source.Environment, source.Generation)
			}
			_, _ = db.ExecContext(cleanup, "DELETE FROM appview_ingestion_leases WHERE environment = $1 AND lease_name = $2", source.Environment, lease.Name)
		})
		for replay := 0; replay < 2; replay++ {
			if err := p.StageBatch(ctx, lease, events, uint64(len(events)), now, ReplayProgress{State: "live"}); err != nil {
				t.Fatal(err)
			}
		}
		snapshot := p.wirePreprocessing.snapshot()
		if enabled {
			if snapshot.inputBatches != 2 || snapshot.inputEvents != 22 || snapshot.committedBatches != 2 || snapshot.acceptedEvents != 12 || snapshot.insertedEvents != 6 || snapshot.filteredPassiveEvents != 10 {
				t.Fatalf("duplicate replay counters = %+v", snapshot)
			}
		} else if snapshot != (wirePreprocessingSnapshot{}) {
			t.Fatalf("disabled compact path reported preprocessing: %+v", snapshot)
		}
		rows, err := db.QueryContext(ctx, "SELECT seq FROM wire_ingestion_inbox WHERE environment = $1 AND source_generation = $2 ORDER BY seq", source.Environment, source.Generation)
		if err != nil {
			t.Fatal(err)
		}
		sequences := []uint64{}
		for rows.Next() {
			var seq uint64
			if err := rows.Scan(&seq); err != nil {
				t.Fatal(err)
			}
			sequences = append(sequences, seq)
		}
		rows.Close()
		if enabled {
			if !reflect.DeepEqual(sequences, original) {
				t.Fatalf("compact %v != original %v", sequences, original)
			}
		} else {
			original = sequences
		}
		if !reflect.DeepEqual(sequences, []uint64{1, 2, 6, 7, 8, 9}) {
			t.Fatalf("unexpected staging %v", sequences)
		}
		checkpoint, err := p.LoadCheckpoint(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if checkpoint == nil || !cursorEquals(checkpoint.LastStagedSeq, uint64(len(events))) {
			t.Fatalf("checkpoint failed to cover filtered/replayed rows: %+v", checkpoint)
		}
		var hasUnused bool
		if err := db.QueryRowContext(ctx, `SELECT payload #> '{commit,record}' ? 'unused' FROM wire_ingestion_inbox WHERE environment = $1 AND source_generation = $2 AND seq = 1`, source.Environment, source.Generation).Scan(&hasUnused); err != nil {
			t.Fatal(err)
		}
		if hasUnused == enabled {
			t.Fatalf("compaction rollout flag ignored: enabled=%v unused=%v", enabled, hasUnused)
		}
	}
}

func TestWireSubjectMembershipLegacyParityIntegration(t *testing.T) {
	url := os.Getenv("JETSTREAM_INGEST_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("JETSTREAM_INGEST_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	db, err := sql.Open("pgx", url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead})
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	// A transaction-local fixture exercises the exact legacy JSON path oracle,
	// including PostgreSQL textualization of malformed numeric and object URIs.
	if _, err := tx.ExecContext(ctx, `CREATE TEMP TABLE wire_item_aliases (alias_key text PRIMARY KEY, expires_at timestamptz) ON COMMIT DROP; INSERT INTO wire_item_aliases VALUES ('at://known', NOW()+INTERVAL '1 day'), ('1000', NOW()+INTERVAL '1 day'), ('true', NOW()+INTERVAL '1 day'), ('{"a": 1}', NOW()+INTERVAL '1 day')`); err != nil {
		t.Fatal(err)
	}
	for _, subject := range []string{`{"uri":"at://known"}`, `"at://known"`, `{"uri":1e3}`, `{"uri":true}`, `{"uri":{"a":1}}`, `{"uri":null}`, `[]`, `{"uri":"missing"}`} {
		event := wireSignal("app.bsky.feed.like", "create", subject)
		var legacy bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM wire_item_aliases WHERE alias_key = $1::jsonb #>> '{commit,record,subject,uri}' AND expires_at > NOW())`, string(event.Payload)).Scan(&legacy); err != nil {
			t.Fatal(err)
		}
		got, err := filterWireSignals(ctx, tx, []ingest.InboxEvent{event})
		if err != nil {
			t.Fatal(err)
		}
		if (len(got) == 1) != legacy {
			t.Fatalf("subject %s changed admission: legacy=%v got=%d", subject, legacy, len(got))
		}
	}
}
