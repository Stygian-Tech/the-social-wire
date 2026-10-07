package wireworkercore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"testing"
	"time"
)

func TestSignalRollupFullIncrementalParityAndWindowExpiry(t *testing.T) {
	db := generationDatabase(t)
	ctx := context.Background()
	id, _ := newGenerationID()
	at := time.Now().UTC().Truncate(time.Microsecond)
	identity := wirecore.Canonicalize("https://" + id + ".example/article")
	t.Cleanup(func() {
		_, _ = db.Exec(`SELECT wire_set_signal_rollup_tracking(false)`)
		_, _ = db.Exec(`DELETE FROM wire_items WHERE canonical_key=$1`, identity.CanonicalKey)
	})
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err = UpsertProjectedItem(ctx, tx, ItemProjection{Identity: *identity, Host: id + ".example", Title: "Article", Language: "en", PresentationSource: "fallback", PresentationPriority: 100, InspectionURL: identity.CanonicalURL, Confidence: .6, TargetKind: wirecore.ExternalArticle, Provenance: []string{"direct_share"}}, at); err != nil {
		tx.Rollback()
		t.Fatal(err)
	}
	for i, kind := range []string{"share", "like", "recommendation"} {
		event := InboxEvent{Repository: InboxRepository{Environment: "dev", SourceGeneration: id}, Sequence: int64(i + 1), SourceHost: "source.example", CursorKind: "jetstream", Collection: nullString("app.bsky.feed.post"), EventTime: at.Add(-time.Duration(i) * 2 * time.Hour)}
		if i == 1 {
			event.Collection = nullString("at.margin.like")
		}
		if err = InsertProjectedSignal(ctx, tx, event, identity.CanonicalKey, "actor-hash-00000000000000001", "at://source/"+kind, kind); err != nil {
			tx.Rollback()
			t.Fatal(err)
		}
	}
	if err = tx.Commit(); err != nil {
		t.Fatal(err)
	}
	full := PostgresSignalRollupStore{DB: db}
	if err = full.Refresh(ctx, at); err != nil {
		t.Fatal(err)
	}
	var first string
	if err = db.QueryRow(`SELECT (to_jsonb(r)-'updated_at')::text FROM wire_signal_rollups r WHERE canonical_key=$1`, identity.CanonicalKey).Scan(&first); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(`SELECT wire_set_signal_rollup_tracking(true)`); err != nil {
		t.Fatal(err)
	}
	incremental := PostgresSignalRollupStore{DB: db, IncrementalEnabled: true}
	if err = incremental.Refresh(ctx, at); err != nil {
		t.Fatal(err)
	}
	var second string
	if err = db.QueryRow(`SELECT (to_jsonb(r)-'updated_at')::text FROM wire_signal_rollups r WHERE canonical_key=$1`, identity.CanonicalKey).Scan(&second); err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatalf("full/incremental differ\n%s\n%s", first, second)
	}
	later := at.Add(25 * time.Hour)
	if err = incremental.Refresh(ctx, later); err != nil {
		t.Fatal(err)
	}
	if err = db.QueryRow(`SELECT (to_jsonb(r)-'updated_at')::text FROM wire_signal_rollups r WHERE canonical_key=$1`, identity.CanonicalKey).Scan(&first); err != nil {
		t.Fatal(err)
	}
	if err = full.Refresh(ctx, later); err != nil {
		t.Fatal(err)
	}
	if err = db.QueryRow(`SELECT (to_jsonb(r)-'updated_at')::text FROM wire_signal_rollups r WHERE canonical_key=$1`, identity.CanonicalKey).Scan(&second); err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatalf("window expiry differs\n%s\n%s", first, second)
	}
	var signals, baseline int
	if err = db.QueryRow(`SELECT signals_24h,baseline_signals_7d FROM wire_signal_rollups WHERE canonical_key=$1`, identity.CanonicalKey).Scan(&signals, &baseline); err != nil {
		t.Fatal(err)
	}
	if signals != 0 || baseline != 2 {
		t.Fatalf("window/baseline %d %d", signals, baseline)
	}
}
