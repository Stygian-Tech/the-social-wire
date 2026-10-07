package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func projectionFixture(t *testing.T) (*PostgresInboxProcessor, string, time.Time) {
	db := generationDatabase(t)
	generation, _ := newGenerationID()
	at := time.Now().UTC().Truncate(time.Microsecond)
	hasher, _ := wirecore.NewActorHasher([]byte(strings.Repeat("x", 32)))
	p := &PostgresInboxProcessor{PostgresInboxClaims: PostgresInboxClaims{DB: db, Scope: &InboxScope{Environment: "dev", Generations: []string{generation}}, BatchSize: 1000, Concurrency: 4}, Hasher: hasher, Standard: StandardRecordApplication{DB: db, Hasher: hasher}, External: PostgresExternalSignalProjector{Hasher: hasher}}
	t.Cleanup(func() {
		_, _ = db.Exec(`DELETE FROM wire_ingestion_inbox WHERE source_generation=$1`, generation)
		_, _ = db.Exec(`DELETE FROM wire_items WHERE source_domain=$1`, generation+".example")
		actor, _ := hasher.Hash("did:example:" + generation)
		_, _ = db.Exec(`DELETE FROM wire_follow_edges WHERE follower_key_hash=$1 OR followee_key_hash=$1`, actor)
		_, _ = db.Exec(`DELETE FROM wire_item_mentions WHERE speaker_key_hash=$1`, actor)
		_, _ = db.Exec(`DELETE FROM wire_active_actors WHERE actor_key_hash=$1`, actor)
		_, _ = db.Exec(`DELETE FROM wire_recommendation_account_fences WHERE repo_did=$1`, "did:example:"+generation)
	})
	return p, generation, at
}
func claimFixture(t *testing.T, p *PostgresInboxProcessor, generation string, seq int64, collection, operation string, record map[string]any, at time.Time) InboxEvent {
	t.Helper()
	payload, _ := json.Marshal(map[string]any{"commit": map[string]any{"record": record}})
	seedInbox(t, p.DB, generation, "did:example:"+generation, seq, "pending", at.Add(-time.Second), collection, operation, string(payload))
	event, err := p.ClaimNext(context.Background(), InboxRepository{"dev", generation, "did:example:" + generation}, at)
	if err != nil {
		t.Fatal(err)
	}
	if event == nil || event.Sequence != seq {
		t.Fatalf("wrong fixture claim %#v", event)
	}
	return *event
}
func TestNormalPostProjectionAndUpdateRetraction(t *testing.T) {
	p, generation, at := projectionFixture(t)
	ctx := context.Background()
	raw := "https://" + generation + ".example/article"
	identity := wirecore.Canonicalize(raw)
	record := map[string]any{"text": "Shared article", "createdAt": at.Format(time.RFC3339), "embed": map[string]any{"$type": "app.bsky.embed.external", "external": map[string]any{"uri": raw, "title": "Publisher title", "description": "Publisher summary"}}, "facets": []any{map[string]any{"features": []any{map[string]any{"$type": "app.bsky.richtext.facet#link", "uri": "https://elsewhere.example"}, map[string]any{"$type": "app.bsky.richtext.facet#mention", "did": "did:example:subject"}}}}}
	event := claimFixture(t, p, generation, 1, "app.bsky.feed.post", "create", record, at)
	if outcome, err := p.ApplyClaimed(ctx, event, at); err != nil || outcome != InboxApplied {
		t.Fatalf("post %s %v", outcome, err)
	}
	var title, source string
	if err := p.DB.QueryRow(`SELECT title,presentation_snapshot->>'metadataSource' FROM wire_items WHERE canonical_key=$1`, identity.CanonicalKey).Scan(&title, &source); err != nil {
		t.Fatal(err)
	}
	if title != "Publisher title" || source != "embedded_card" {
		t.Fatalf("wrong metadata %s %s", title, source)
	}
	var count int
	if err := p.DB.QueryRow(`SELECT count(*) FROM wire_item_mentions WHERE source_uri=$1`, event.SourceURI()).Scan(&count); err != nil || count != 1 {
		t.Fatalf("mentions %d %v", count, err)
	}
	update := claimFixture(t, p, generation, 2, "app.bsky.feed.post", "update", map[string]any{"text": "No longer sharing an article"}, at.Add(time.Second))
	if outcome, err := p.ApplyClaimed(ctx, update, at.Add(time.Second)); err != nil || outcome != InboxApplied {
		t.Fatalf("update %s %v", outcome, err)
	}
	if err := p.DB.QueryRow(`SELECT count(*) FROM wire_signal_events WHERE source_uri=$1`, event.SourceURI()).Scan(&count); err != nil || count != 0 {
		t.Fatalf("retraction %d %v", count, err)
	}
	if err := p.DB.QueryRow(`SELECT count(*) FROM wire_item_mentions WHERE source_uri=$1`, event.SourceURI()).Scan(&count); err != nil || count != 0 {
		t.Fatalf("mention retraction %d %v", count, err)
	}
}
func TestExternalSignalsReplaceAndPassiveUnresolvedLike(t *testing.T) {
	p, generation, at := projectionFixture(t)
	ctx := context.Background()
	raw := "https://" + generation + ".example/article"
	identity := wirecore.Canonicalize(raw)
	record := map[string]any{"motivation": "bookmarking", "createdAt": at.Format(time.RFC3339), "target": map[string]any{"source": raw}, "title": "External article"}
	event := claimFixture(t, p, generation, 1, "at.margin.note", "create", record, at)
	if outcome, err := p.ApplyClaimed(ctx, event, at); err != nil || outcome != InboxApplied {
		t.Fatalf("external note %s %v", outcome, err)
	}
	var count int
	if err := p.DB.QueryRow(`SELECT count(*) FROM wire_signal_events WHERE canonical_key=$1 AND source_collection='at.margin.note' AND source_action='bookmarking'`, identity.CanonicalKey).Scan(&count); err != nil || count != 1 {
		t.Fatalf("external signals %d %v", count, err)
	}
	like := claimFixture(t, p, generation, 2, "at.margin.like", "create", map[string]any{"createdAt": at.Format(time.RFC3339), "subject": map[string]any{"uri": "at://missing/note"}}, at.Add(time.Second))
	if outcome, err := p.ApplyClaimed(ctx, like, at.Add(time.Second)); err != nil || outcome != InboxApplied {
		t.Fatalf("passive margin like %s %v", outcome, err)
	}
	bad := claimFixture(t, p, generation, 3, "network.cosmik.connection", "create", map[string]any{"source": raw, "target": "at://missing/card"}, at.Add(2*time.Second))
	if outcome, err := p.ApplyClaimed(ctx, bad, at.Add(2*time.Second)); err != nil || outcome != InboxRetry {
		t.Fatalf("unresolved connection %s %v", outcome, err)
	}
	var failure sql.NullString
	if err := p.DB.QueryRow(`SELECT failure_category FROM wire_ingestion_inbox WHERE source_generation=$1 AND seq=3`, generation).Scan(&failure); err != nil {
		t.Fatal(err)
	}
	if failure.String != "unresolved_subject" {
		t.Fatalf("failure %s", failure.String)
	}
}
func TestInactiveAccountRetractsActorsAndRejectsOlderReactivation(t *testing.T) {
	p, generation, at := projectionFixture(t)
	ctx := context.Background()
	raw := "https://" + generation + ".example/article"
	record := map[string]any{"text": "Article", "embed": map[string]any{"external": map[string]any{"uri": raw}}}
	post := claimFixture(t, p, generation, 1, "app.bsky.feed.post", "create", record, at)
	if outcome, err := p.ApplyClaimed(ctx, post, at); err != nil || outcome != InboxApplied {
		t.Fatalf("post %s %v", outcome, err)
	}
	for index, active := range []bool{false, true} {
		seq := int64(index + 2)
		payload := fmt.Sprintf(`{"account":{"active":%t}}`, active)
		eventAt := at.Add(time.Second)
		if active {
			eventAt = at
		}
		_, err := p.DB.Exec(`INSERT INTO wire_ingestion_inbox(environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,payload,event_time,status,next_attempt_at) VALUES('dev',$1,$2,'jetstream.example','jetstream_us','account',$3,$4::jsonb,$5,'pending',$5)`, generation, seq, post.Repository.RepoDID, payload, eventAt)
		if err != nil {
			t.Fatal(err)
		}
		event, err := p.ClaimNext(ctx, post.Repository, at.Add(2*time.Second))
		if err != nil {
			t.Fatal(err)
		}
		if outcome, err := p.ApplyClaimed(ctx, *event, at.Add(2*time.Second)); err != nil || outcome != InboxApplied {
			t.Fatalf("account %s %v", outcome, err)
		}
	}
	var active bool
	if err := p.DB.QueryRow(`SELECT active FROM wire_recommendation_account_fences WHERE repo_did=$1`, post.Repository.RepoDID).Scan(&active); err != nil {
		t.Fatal(err)
	}
	if active {
		t.Fatal("older activation erased inactive fence")
	}
	var count int
	actor, _ := p.Hasher.Hash(post.Repository.RepoDID)
	if err := p.DB.QueryRow(`SELECT count(*) FROM wire_signal_events WHERE actor_key_hash=$1`, actor).Scan(&count); err != nil || count != 0 {
		t.Fatalf("inactive signals %d %v", count, err)
	}
}
