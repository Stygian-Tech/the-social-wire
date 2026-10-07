package wireworkercore

import (
	"context"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func recommendationFixture(t *testing.T) (*PostgresInboxProcessor, *PostgresRecommendationJournal, string, time.Time, string) {
	p, generation, at := projectionFixture(t)
	journal := &PostgresRecommendationJournal{DB: p.DB}
	p.Recommendations = journal
	p.DeferredRecommendations = true
	t.Cleanup(func() {
		_, _ = p.DB.Exec(`DELETE FROM wire_recommendation_record_fences WHERE source_generation=$1`, generation)
		_, _ = p.DB.Exec(`DELETE FROM wire_recommendation_dependency_recovery WHERE source_generation=$1`, generation)
		_, _ = p.DB.Exec(`DELETE FROM wire_recommendation_journal WHERE source_generation=$1`, generation)
	})
	post := claimFixture(t, p, generation, 1, "app.bsky.feed.post", "create", map[string]any{"text": "Article", "embed": map[string]any{"external": map[string]any{"uri": "https://" + generation + ".example/article"}}}, at)
	if outcome, err := p.ApplyClaimed(context.Background(), post, at); err != nil || outcome != InboxApplied {
		t.Fatalf("post %s %v", outcome, err)
	}
	return p, journal, generation, at, post.SourceURI()
}
func TestRecommendationLostProjectionRepairDoesNotInflateActors(t *testing.T) {
	p, journal, generation, at, subject := recommendationFixture(t)
	ctx := context.Background()
	recommend := claimFixture(t, p, generation, 2, "site.standard.graph.recommend", "create", map[string]any{"document": subject}, at.Add(time.Second))
	if _, err := p.DB.Exec(`UPDATE wire_ingestion_inbox SET repo_rev='2222222222222',record_cid='cid-original' WHERE source_generation=$1 AND seq=2`, generation); err != nil {
		t.Fatal(err)
	}
	if outcome, err := p.ApplyClaimed(ctx, recommend, at.Add(time.Second)); err != nil || outcome != InboxApplied {
		t.Fatalf("recommendation %s %v", outcome, err)
	}
	actor, _ := p.Hasher.Hash(recommend.Repository.RepoDID)
	var before, after int
	if err := p.DB.QueryRow(`SELECT public_signal_count FROM wire_active_actors WHERE actor_key_hash=$1`, actor).Scan(&before); err != nil {
		t.Fatal(err)
	}
	if _, err := p.DB.Exec(`DELETE FROM wire_signal_events WHERE source_uri=$1`, recommend.SourceURI()); err != nil {
		t.Fatal(err)
	}
	counts, err := journal.Recover(ctx, at.Add(2*time.Second), 50, &InboxScope{Environment: "dev", Generations: []string{generation}})
	if err != nil {
		t.Fatal(err)
	}
	if counts.Resolved != 1 {
		t.Fatalf("repair counts %#v", counts)
	}
	if err := p.DB.QueryRow(`SELECT public_signal_count FROM wire_active_actors WHERE actor_key_hash=$1`, actor).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if after != before {
		t.Fatalf("recovery inflated actor count %d→%d", before, after)
	}
	counts, err = journal.Recover(ctx, at.Add(3*time.Second), 50, &InboxScope{Environment: "dev", Generations: []string{generation}})
	if err != nil {
		t.Fatal(err)
	}
	if counts.Attempted != 0 {
		t.Fatalf("already repaired projection reprocessed %#v", counts)
	}
}
func TestRecommendationDeferredUpdateAndDeleteFence(t *testing.T) {
	p, journal, generation, at, subject := recommendationFixture(t)
	ctx := context.Background()
	original := claimFixture(t, p, generation, 2, "site.standard.graph.recommend", "create", map[string]any{"document": subject}, at.Add(time.Second))
	if _, err := p.DB.Exec(`UPDATE wire_ingestion_inbox SET repo_rev='2222222222222',record_cid='first' WHERE source_generation=$1 AND seq=2`, generation); err != nil {
		t.Fatal(err)
	}
	if outcome, err := p.ApplyClaimed(ctx, original, at.Add(time.Second)); err != nil || outcome != InboxApplied {
		t.Fatalf("original %s %v", outcome, err)
	}
	update := claimFixture(t, p, generation, 3, "site.standard.graph.recommend", "update", map[string]any{"document": "at://missing/document"}, at.Add(2*time.Second))
	if _, err := p.DB.Exec(`UPDATE wire_ingestion_inbox SET repo_rev='3333333333333',record_cid='second' WHERE source_generation=$1 AND seq=3`, generation); err != nil {
		t.Fatal(err)
	}
	if outcome, err := p.ApplyClaimed(ctx, update, at.Add(2*time.Second)); err != nil || outcome != InboxDeferred {
		t.Fatalf("update %s %v", outcome, err)
	}
	var count int
	if err := p.DB.QueryRow(`SELECT count(*) FROM wire_signal_events WHERE source_uri=$1`, original.SourceURI()).Scan(&count); err != nil || count != 0 {
		t.Fatalf("unresolved update endorsed old subject %d %v", count, err)
	}
	deletion := claimFixture(t, p, generation, 4, "site.standard.graph.recommend", "delete", nil, at.Add(3*time.Second))
	if _, err := p.DB.Exec(`UPDATE wire_ingestion_inbox SET repo_rev='4444444444444' WHERE source_generation=$1 AND seq=4`, generation); err != nil {
		t.Fatal(err)
	}
	if outcome, err := p.ApplyClaimed(ctx, deletion, at.Add(3*time.Second)); err != nil || outcome != InboxApplied {
		t.Fatalf("delete %s %v", outcome, err)
	}
	identity := wirecore.Canonicalize("https://" + generation + ".example/article")
	if _, err := p.DB.Exec(`INSERT INTO wire_item_aliases(alias_key,canonical_key,alias_type,expires_at) VALUES('at://missing/document',$1,'at_uri',$2)`, identity.CanonicalKey, at.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = p.DB.Exec(`DELETE FROM wire_item_aliases WHERE alias_key='at://missing/document'`) })
	counts, err := journal.Recover(ctx, at.Add(5*time.Minute), 50, &InboxScope{Environment: "dev", Generations: []string{generation}})
	if err != nil {
		t.Fatal(err)
	}
	if counts.Attempted != 0 {
		t.Fatalf("delete resurrected pending work %#v", counts)
	}
}
func TestRetriedRecommendationRequiresCurrentRecordProof(t *testing.T) {
	p, journal, generation, at, subject := recommendationFixture(t)
	journal.DependencyVerification = true
	recommend := claimFixture(t, p, generation, 2, "site.standard.graph.recommend", "create", map[string]any{"document": subject}, at.Add(time.Second))
	if _, err := p.DB.Exec(`UPDATE wire_ingestion_inbox SET attempt_count=2,repo_rev='2222222222222',record_cid='original' WHERE source_generation=$1 AND seq=2`, generation); err != nil {
		t.Fatal(err)
	}
	if outcome, err := p.ApplyClaimed(context.Background(), recommend, at.Add(time.Second)); err != nil || outcome != InboxDeferred {
		t.Fatalf("retried original %s %v", outcome, err)
	}
	var reason string
	if err := p.DB.QueryRow(`SELECT failure_reason FROM wire_recommendation_journal WHERE source_generation=$1 AND seq=2`, generation).Scan(&reason); err != nil {
		t.Fatal(err)
	}
	if reason != "dependency_verification_required" {
		t.Fatalf("retry bypassed proof: %s", reason)
	}
}
