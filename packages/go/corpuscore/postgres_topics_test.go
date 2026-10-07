package corpuscore

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"testing"
	"time"
)

func TestPostgresTopicGenerationsFailClosed(t *testing.T) {
	db := corpusDB(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	id := "bcb217b1-7d19-4120-a8af-f2bd2c5f3333"
	key := "corpus-topic-generation"
	labeler := "did:example:corpus-topic"
	t.Cleanup(func() {
		db.Exec(`DELETE FROM finance_generations WHERE generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM sports_generations WHERE generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM wire_items WHERE canonical_key=$1`, key)
		db.Exec(`DELETE FROM wire_label_refresh_state WHERE source_did=$1`, labeler)
	})
	execFixture(t, db, `INSERT INTO wire_label_refresh_state(source_did,endpoint_host,last_attempted_at,last_successful_at,target_count,label_count,is_current) VALUES($1,'labels.example',$2,$2,0,0,TRUE)`, labeler, now)
	for _, table := range []string{"finance_generations", "sports_generations"} {
		execFixture(t, db, `INSERT INTO `+table+`(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload,is_active) VALUES($1::uuid,$1::uuid,'en','fixture',$2,$3,'[]'::jsonb,TRUE)`, id, now, now.Add(time.Hour))
	}
	store := &PostgreSQLStore{DB: db}
	if value, err := store.Finance(ctx, "en", now); err != nil || value.GenerationID != id || len(value.Candidates) != 0 {
		t.Fatal(value, err)
	}
	if value, err := store.Sports(ctx, "en", now); err != nil || value.GenerationID != id || len(value.Candidates) != 0 {
		t.Fatal(value, err)
	}
	execFixture(t, db, `INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at,language_code) VALUES($1,'https://example.com/topic','example.com','Example','Topic',$2,$2,$3,'en')`, key, now, now.Add(time.Hour))
	candidate := sportscore.RankCandidate{Item: wirecore.FeedItem{ItemID: key, CanonicalURL: "https://example.com/topic", Title: "Topic", Source: wirecore.ItemSource{Name: "Example", Domain: "example.com"}, Reasons: []wirecore.ReasonCode{}, Provenance: []string{}}, Analysis: sportscore.ArticleAnalysis{ResolverVersion: sportscore.ResolverVersion, Eligible: true, Materiality: "fixture", Associations: []sportscore.Association{{EntityID: "fixture", ResolverVersion: "old", Evidence: []string{}}}, SportIDs: []string{}, CompetitionIDs: []string{}}}
	payload, _ := json.Marshal([]sportscore.RankCandidate{candidate})
	execFixture(t, db, `UPDATE sports_generations SET payload=$2::jsonb WHERE generation_id=$1::uuid`, id, string(payload))
	if _, err := store.Sports(ctx, "en", now); !errors.Is(err, ErrUnavailable) {
		t.Fatal("stale association accepted", err)
	}
	candidate.Analysis.Associations[0].ResolverVersion = sportscore.ResolverVersion
	payload, _ = json.Marshal([]sportscore.RankCandidate{candidate})
	execFixture(t, db, `UPDATE sports_generations SET payload=$2::jsonb WHERE generation_id=$1::uuid`, id, string(payload))
	if value, err := store.Sports(ctx, "en", now); err != nil || len(value.Candidates) != 1 {
		t.Fatal(value, err)
	}
	execFixture(t, db, `UPDATE sports_generations SET payload=jsonb_build_array(jsonb_build_object('item',jsonb_build_object('itemId',$2::text))) WHERE generation_id=$1::uuid`, id, key)
	if _, err := store.Sports(ctx, "en", now); !errors.Is(err, ErrContractMismatch) {
		t.Fatal("malformed required fields accepted", err)
	}
	execFixture(t, db, `UPDATE finance_generations SET expires_at=$2 WHERE generation_id=$1::uuid`, id, now.Add(-time.Second))
	if _, err := store.Finance(ctx, "en", now); !errors.Is(err, ErrUnavailable) {
		t.Fatal("expired finance generation", err)
	}
}
