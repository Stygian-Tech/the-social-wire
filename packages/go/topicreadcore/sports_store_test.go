package topicreadcore

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"strings"
	"testing"
	"time"
)

func TestSportsPostgresSnapshotLiveChangesAndResolverGate(t *testing.T) {
	db := selectionDB(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	id := "88888888-2222-2222-2222-222222222222"
	entity := sportscore.Entity{ID: "topic-sports-team", Name: "Fixture Football Club", Kind: "team", CompetitionIDs: []string{}, Aliases: []string{}, ProviderIDs: map[string]string{}, Memberships: []sportscore.Membership{}, Active: true}
	raw, _ := corpuscore.MarshalHTTP(entity)
	if _, err := db.Exec(`INSERT INTO sports_entities(entity_id,payload,updated_at)VALUES($1,$2::jsonb,$3)`, entity.ID, raw, now); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		db.Exec(`DELETE FROM sports_generations WHERE generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM sports_entities WHERE entity_id=$1`, entity.ID)
	})
	fixture := &financeWireFixture{items: map[string]wirecore.FeedItem{}}
	candidates := []sportscore.RankCandidate{}
	for index, title := range []string{"Fixture Football Club wins championship final", "Fixture Football Club signs new player", "Fixture Football Club sets new season record"} {
		item := topicItem(string(rune('x' + index)))
		item.Title = title
		fixture.items[item.ItemID] = item
		analysis := sportscore.ArticleAnalysis{ResolverVersion: sportscore.ResolverVersion, Eligible: true, Materiality: "championship", Associations: []sportscore.Association{{EntityID: entity.ID, Confidence: 1, Prominence: 1, Evidence: []string{"reviewed-alias"}, ResolverVersion: sportscore.ResolverVersion}}, SportIDs: []string{}, CompetitionIDs: []string{}}
		candidates = append(candidates, sportscore.RankCandidate{Item: item, Analysis: analysis, BaseScore: float64(3 - index)})
	}
	payload, _ := corpuscore.MarshalHTTP(candidates)
	if _, err := db.Exec(`INSERT INTO sports_generations(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload,is_active)VALUES($1::uuid,$1::uuid,'en','sports-v1',$2,$3,$4::jsonb,TRUE)`, id, now, now.Add(time.Hour), payload); err != nil {
		t.Fatal(err)
	}
	wire, err := NewWireStore(fixture, strings.Repeat("w", 32), "visible", NewModerationService(nil, nil).Cache)
	if err != nil {
		t.Fatal(err)
	}
	s, err := NewSportsStore(db, wire, &SelectionProjection{DB: db}, map[string]string{"SPORTS_FEED_MODE": "visible", "WIRE_CURSOR_HMAC_SECRET": strings.Repeat("s", 32)})
	if err != nil {
		t.Fatal(err)
	}
	page, err := s.Page(ctx, "", 1, "en", "", false, now, "sports", nil)
	if err != nil || len(page.Items) != 1 || page.Cursor == nil {
		t.Fatal(page, err)
	}
	changed := fixture.items["y"]
	changed.Title = "A soup recipe for dinner"
	fixture.items["y"] = changed
	next, err := s.Page(ctx, *page.Cursor, 1, "en", "", false, now, "sports", nil)
	if err != nil || len(next.Items) != 1 || next.Items[0].Story.ItemID != "z" || next.Cursor != nil {
		t.Fatal(next, err)
	}
	outside := "outside-us"
	if _, err = s.Page(ctx, *page.Cursor, 1, "en", "", false, now, "sports", &outside); !errors.Is(err, ErrInvalidCursor) {
		t.Fatal("region context escaped", err)
	}
	if _, err = s.Page(ctx, *page.Cursor, 1, "en", "different-viewer", false, now, "sports", nil); !errors.Is(err, ErrInvalidCursor) {
		t.Fatal("viewer context escaped", err)
	}
	var payloadJSON []map[string]any
	if err = json.Unmarshal(payload, &payloadJSON); err != nil {
		t.Fatal(err)
	}
	payloadJSON[0]["analysis"].(map[string]any)["resolverVersion"] = "old"
	old, _ := json.Marshal(payloadJSON)
	if _, err = db.Exec(`UPDATE sports_personalized_snapshots SET payload=$2::jsonb WHERE snapshot_id=$1::uuid`, page.GenerationID, old); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Page(ctx, *page.Cursor, 1, "en", "", false, now, "sports", nil); !errors.Is(err, ErrCursorExpired) {
		t.Fatal("old resolver snapshot served", err)
	}
}
