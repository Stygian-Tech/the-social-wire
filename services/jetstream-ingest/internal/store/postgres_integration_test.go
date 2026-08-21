package store

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func TestPostgresStageWireBatchNormalizesUnsupportedUnicode(t *testing.T) {
	databaseURL := os.Getenv("JETSTREAM_INGEST_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("JETSTREAM_INGEST_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	generation := fmt.Sprintf("integration-wire-%d", time.Now().UnixNano())
	source := ingest.SourceIdentity{
		PipelineMode: config.WirePipelineMode, Environment: "dev",
		Host: "jetstream.us-west.bsky.network", StreamNSID: "network.bsky.jetstream.subscribeEvents",
		FilterFingerprint: "integration-wire-filter", CursorKind: "jetstream_v2_seq",
		Generation: generation,
	}
	postgres := New(db, source)
	lease, err := postgres.AcquireLease(ctx, "integration-"+generation, "integration-owner", 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		_, _ = db.ExecContext(cleanup, "DELETE FROM wire_ingestion_inbox WHERE environment = $1 AND source_generation = $2", source.Environment, generation)
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_jetstream_checkpoints WHERE environment = $1 AND source_generation = $2", source.Environment, generation)
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_ingestion_leases WHERE environment = $1 AND lease_name = $2", source.Environment, lease.Name)
	})

	now := time.Now().UTC()
	event := ingest.InboxEvent{
		Seq: 177, Time: now, Kind: "commit", RepoDID: "did:plc:wire-integration",
		Payload: []byte(`{"record":{"text":"before\u0000after","literal":"\\u0000"},"cursor":177}`),
	}
	if err := postgres.StageBatch(
		ctx, lease, []ingest.InboxEvent{event}, event.Seq, now,
		ReplayProgress{State: "live", LastProgressAt: now},
	); err != nil {
		t.Fatal(err)
	}
	var text, literal string
	if err := db.QueryRowContext(ctx, `
		SELECT payload->'record'->>'text', payload->'record'->>'literal'
		FROM wire_ingestion_inbox
		WHERE environment = $1 AND source_generation = $2 AND seq = $3`,
		source.Environment, generation, int64(event.Seq)).Scan(&text, &literal); err != nil {
		t.Fatal(err)
	}
	if text != "before�after" || literal != `\u0000` {
		t.Fatalf("stored normalized strings text=%q literal=%q", text, literal)
	}

	malformed := event
	malformed.Seq = 178
	malformed.Payload = []byte(`{"record":`)
	if err := postgres.StageBatch(
		ctx, lease, []ingest.InboxEvent{malformed}, malformed.Seq, now,
		ReplayProgress{State: "live", LastProgressAt: now},
	); err != nil {
		t.Fatal(err)
	}
	var failureCode string
	var originalBytes int
	if err := db.QueryRowContext(ctx, `
		SELECT payload->'$wireIngestionError'->>'code',
		       (payload->'$wireIngestionError'->>'originalBytes')::integer
		FROM wire_ingestion_inbox
		WHERE environment = $1 AND source_generation = $2 AND seq = $3`,
		source.Environment, generation, int64(malformed.Seq)).Scan(&failureCode, &originalBytes); err != nil {
		t.Fatal(err)
	}
	if failureCode != wirePayloadNormalizationFailureCode || originalBytes != len(malformed.Payload) {
		t.Fatalf("stored fallback code=%q originalBytes=%d", failureCode, originalBytes)
	}
	checkpoint, err := postgres.LoadCheckpoint(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if checkpoint == nil || checkpoint.LastStagedSeq != malformed.Seq {
		t.Fatalf("checkpoint did not advance over fallback payload: %#v", checkpoint)
	}
}

func TestPostgresStageBatchIntegration(t *testing.T) {
	databaseURL := os.Getenv("JETSTREAM_INGEST_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("JETSTREAM_INGEST_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	generation := fmt.Sprintf("integration-%d", time.Now().UnixNano())
	source := ingest.SourceIdentity{
		Environment: "dev", Host: "jetstream.us-west.bsky.network",
		StreamNSID: "network.bsky.jetstream.subscribeEvents", FilterFingerprint: "integration-filter",
		CursorKind: "jetstream_v2_seq", Generation: generation,
	}
	postgres := New(db, source)
	lease, err := postgres.AcquireLease(ctx, "integration-"+generation, "integration-owner", 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_ingestion_inbox WHERE environment = $1 AND source_generation = $2", source.Environment, generation)
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_jetstream_checkpoints WHERE environment = $1 AND source_generation = $2", source.Environment, generation)
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_ingestion_leases WHERE environment = $1 AND lease_name = $2", source.Environment, lease.Name)
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_viewer_feeds WHERE viewer_did IN ('did:plc:integration-viewer', 'did:plc:integration-dual')")
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_publication_scopes WHERE viewer_did IN ('did:plc:integration-viewer', 'did:plc:integration-dual')")
	})
	if _, err := db.ExecContext(ctx, `
		INSERT INTO appview_publication_scopes (viewer_did, publication_id, author_did)
		VALUES ('did:plc:integration-viewer', 'at://did:plc:integration/site.standard.publication/test', 'did:plc:integration')`); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	contentCollection := "site.standard.entry"
	event := ingest.InboxEvent{
		Seq: 77, Time: now, Kind: "commit", RepoDID: "did:plc:integration",
		Collection: &contentCollection,
		Payload:    []byte(`{"did":"did:plc:integration","cursor":77,"time_us":1,"kind":"commit","commit":{"operation":"delete","collection":"site.standard.entry","rkey":"one","rev":"one"}}`),
	}
	if err := postgres.StageBatch(ctx, lease, []ingest.InboxEvent{event}, 77, now, ReplayProgress{State: "live", LastProgressAt: now}); err != nil {
		t.Fatal(err)
	}
	var kind string
	var cursor int64
	err = db.QueryRowContext(ctx, `
		SELECT payload->>'kind', payload->>'cursor'
		FROM appview_ingestion_inbox
		WHERE environment = $1 AND source_generation = $2 AND seq = 77`, source.Environment, generation).
		Scan(&kind, &cursor)
	if err != nil {
		t.Fatal(err)
	}
	if kind != "commit" || cursor != 77 {
		t.Fatalf("stored payload kind=%q cursor=%d", kind, cursor)
	}
	checkpoint, err := postgres.LoadCheckpoint(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if checkpoint == nil || checkpoint.LastStagedSeq != 77 {
		t.Fatalf("checkpoint = %#v", checkpoint)
	}

	untracked := event
	untracked.Seq = 78
	untracked.RepoDID = "did:plc:not-enrolled"
	untracked.Payload = []byte(`{"cursor":78,"kind":"commit"}`)
	if err := postgres.StageBatch(ctx, lease, []ingest.InboxEvent{untracked}, 78, now, ReplayProgress{State: "live", LastProgressAt: now}); err != nil {
		t.Fatal(err)
	}
	var untrackedCount int
	if err := db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM appview_ingestion_inbox
		WHERE environment = $1 AND source_generation = $2 AND seq = 78`, source.Environment, generation).
		Scan(&untrackedCount); err != nil {
		t.Fatal(err)
	}
	if untrackedCount != 0 {
		t.Fatalf("untracked author commits staged = %d", untrackedCount)
	}
	checkpoint, err = postgres.LoadCheckpoint(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if checkpoint == nil || checkpoint.LastStagedSeq != 78 {
		t.Fatalf("checkpoint did not advance over filtered sequence: %#v", checkpoint)
	}

	if _, err := db.ExecContext(ctx, `
		INSERT INTO appview_viewer_feeds (viewer_did, feed_kind, feed_id)
		VALUES ('did:plc:integration-viewer', 'subscribed', '')`); err != nil {
		t.Fatal(err)
	}
	subscriptionCollection := "app.skyreader.feed.subscription"
	viewerEvent := event
	viewerEvent.Seq = 79
	viewerEvent.RepoDID = "did:plc:integration-viewer"
	viewerEvent.Collection = &subscriptionCollection
	viewerEvent.Payload = []byte(`{"cursor":79,"kind":"commit"}`)
	if err := postgres.StageBatch(ctx, lease, []ingest.InboxEvent{viewerEvent}, 79, now, ReplayProgress{State: "live", LastProgressAt: now}); err != nil {
		t.Fatal(err)
	}
	var viewerCount int
	if err := db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM appview_ingestion_inbox
		WHERE environment = $1 AND source_generation = $2 AND seq = 79`, source.Environment, generation).
		Scan(&viewerCount); err != nil {
		t.Fatal(err)
	}
	if viewerCount != 1 {
		t.Fatalf("tracked viewer commits staged = %d", viewerCount)
	}

	viewerAsAuthor := event
	viewerAsAuthor.Seq = 80
	viewerAsAuthor.RepoDID = "did:plc:integration-viewer"
	viewerAsAuthor.Payload = []byte(`{"cursor":80,"kind":"commit"}`)
	authorAsViewer := event
	authorAsViewer.Seq = 81
	authorAsViewer.Collection = &subscriptionCollection
	authorAsViewer.Payload = []byte(`{"cursor":81,"kind":"commit"}`)
	if err := postgres.StageBatch(ctx, lease, []ingest.InboxEvent{viewerAsAuthor, authorAsViewer}, 81, now, ReplayProgress{State: "live", LastProgressAt: now}); err != nil {
		t.Fatal(err)
	}
	var crossRoleCount int
	if err := db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM appview_ingestion_inbox
		WHERE environment = $1 AND source_generation = $2 AND seq IN (80, 81)`, source.Environment, generation).
		Scan(&crossRoleCount); err != nil {
		t.Fatal(err)
	}
	if crossRoleCount != 0 {
		t.Fatalf("cross-role commits staged = %d", crossRoleCount)
	}

	if _, err := db.ExecContext(ctx, `
		INSERT INTO appview_publication_scopes (viewer_did, publication_id, author_did)
		VALUES ('did:plc:integration-dual', 'at://did:plc:integration-dual/site.standard.publication/test', 'did:plc:integration-dual')`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `
		INSERT INTO appview_viewer_feeds (viewer_did, feed_kind, feed_id)
		VALUES ('did:plc:integration-dual', 'subscribed', '')`); err != nil {
		t.Fatal(err)
	}
	dualContent := event
	dualContent.Seq = 82
	dualContent.RepoDID = "did:plc:integration-dual"
	dualContent.Payload = []byte(`{"cursor":82,"kind":"commit"}`)
	dualSubscription := dualContent
	dualSubscription.Seq = 83
	dualSubscription.Collection = &subscriptionCollection
	dualSubscription.Payload = []byte(`{"cursor":83,"kind":"commit"}`)
	if err := postgres.StageBatch(ctx, lease, []ingest.InboxEvent{dualContent, dualSubscription}, 83, now, ReplayProgress{State: "live", LastProgressAt: now}); err != nil {
		t.Fatal(err)
	}
	var dualRoleCount int
	if err := db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM appview_ingestion_inbox
		WHERE environment = $1 AND source_generation = $2 AND seq IN (82, 83)`, source.Environment, generation).
		Scan(&dualRoleCount); err != nil {
		t.Fatal(err)
	}
	if dualRoleCount != 2 {
		t.Fatalf("dual-role commits staged = %d", dualRoleCount)
	}
	checkpoint, err = postgres.LoadCheckpoint(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if checkpoint == nil || checkpoint.LastStagedSeq != 83 {
		t.Fatalf("sparse admission checkpoint = %#v", checkpoint)
	}
}
