package topicreadcore

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func leanSnapshotCandidate(id string) sportscore.RankCandidate {
	item := wirecore.FeedItem{ItemID: id, CanonicalURL: "https://example.com/" + id, Title: "Fixture Football Club wins championship " + id, Source: wirecore.ItemSource{Domain: "example.com"}, Reasons: []wirecore.ReasonCode{}, Provenance: []string{}}
	return sportscore.RankCandidate{Item: item, PresentationFingerprint: sportscore.PresentationFingerprint(item), Analysis: sportscore.ArticleAnalysis{ResolverVersion: sportscore.ResolverVersion, Eligible: true, Materiality: "championship", Associations: []sportscore.Association{}, SportIDs: []string{}, CompetitionIDs: []string{}}, BaseScore: 1}
}

func TestSportsSnapshotCompatibilityOnlyExplicitTaskShape(t *testing.T) {
	candidate := leanSnapshotCandidate("story")
	candidate.Item.Reasons = nil
	candidate.Item.Provenance = nil
	raw, _ := corpuscore.MarshalHTTP([]sportscore.RankCandidate{candidate})
	before := string(raw)
	var decoded []sportscore.RankCandidate
	if err := decodeSportsSnapshot(raw, &decoded); err != nil || len(decoded) != 1 || decoded[0].Item.Reasons == nil || decoded[0].Item.Provenance == nil || string(raw) != before {
		t.Fatal(decoded, err)
	}
	for _, mutation := range []func(map[string]any){
		func(c map[string]any) { delete(c, "presentationFingerprint") },
		func(c map[string]any) { c["presentationFingerprint"] = strings.Repeat("A", 64) },
		func(c map[string]any) { c["presentationFingerprint"] = "invalid" },
		func(c map[string]any) { delete(c["item"].(map[string]any), "reasons") },
		func(c map[string]any) { c["item"].(map[string]any)["provenance"] = []any{} },
		func(c map[string]any) { delete(c["item"].(map[string]any), "title") },
		func(c map[string]any) { delete(c["analysis"].(map[string]any), "eligible") },
	} {
		var rows []map[string]any
		_ = json.Unmarshal(raw, &rows)
		mutation(rows[0])
		invalid, _ := json.Marshal(rows)
		if err := decodeSportsSnapshot(invalid, &decoded); !errors.Is(err, corpuscore.ErrContractMismatch) {
			t.Fatal("broader malformed snapshot accepted", string(invalid), err)
		}
	}
}

type leanPageCorpus struct {
	corpuscore.Store
	response corpuscore.SportsSourceResponse
}

func (f *leanPageCorpus) SportsSource(context.Context, corpuscore.SportsSourceRequest, time.Time) (corpuscore.SportsSourceResponse, error) {
	return f.response, nil
}

func TestPostgresNonemptyLeanSportsPagePersistenceAndTaskCompatibility(t *testing.T) {
	db := selectionDB(t)
	now := time.Now().UTC().Truncate(time.Second)
	id := "aaaaaaaa-4444-4444-4444-444444444444"
	catalogID := "bbbbbbbb-4444-4444-4444-444444444444"
	entity := sportscore.Entity{ID: "lean-fixture-team", Name: "Fixture Football Club", Kind: "team", CompetitionIDs: []string{}, Aliases: []string{}, ProviderIDs: map[string]string{}, Active: true}
	entities := []sportscore.Entity{entity}
	catalogRaw, _ := json.Marshal(map[string]any{"entities": entities})
	revision, _ := sportscore.ServingCatalogRevision(entities)
	t.Cleanup(func() {
		db.Exec(`DELETE FROM sports_generations WHERE generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM sports_catalog_snapshots WHERE snapshot_id=$1::uuid`, catalogID)
	})
	if _, err := db.Exec(`INSERT INTO sports_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active)VALUES($1::uuid,'lean-page-fixture',$2,$3::jsonb,TRUE)`, catalogID, now, string(catalogRaw)); err != nil {
		t.Fatal(err)
	}
	candidates := []corpuscore.SportsSourceCandidate{}
	current := &financeWireFixture{items: map[string]wirecore.FeedItem{}}
	for index, id := range []string{"first", "second", "third"} {
		candidate := leanSnapshotCandidate(id)
		candidate.BaseScore = float64(3 - index)
		candidate.Analysis.Associations = []sportscore.Association{{EntityID: entity.ID, Confidence: 1, Evidence: []string{}, ResolverVersion: sportscore.ResolverVersion}}
		current.items[id] = candidate.Item
		candidates = append(candidates, corpuscore.SportsSourceCandidate{ItemID: id, CanonicalURL: candidate.Item.CanonicalURL, Title: candidate.Item.Title, Domain: candidate.Item.Source.Domain, PresentationFingerprint: candidate.PresentationFingerprint, Analysis: candidate.Analysis, BaseScore: candidate.BaseScore})
	}
	remote := &leanPageCorpus{response: corpuscore.SportsSourceResponse{GenerationID: id, GenerationRevision: strings.Repeat("a", 64), GeneratedAt: now, ExpiresAt: now.Add(time.Hour), Language: "en", ResolverVersion: sportscore.ResolverVersion, CatalogVersion: "lean-page-fixture", CatalogGeneratedAt: now.Format(time.RFC3339Nano), CatalogRevision: revision, ServingCatalogRevision: revision, Candidates: &candidates}}
	moderation := NewModerationService(nil, nil)
	wire, err := NewWireStore(current, strings.Repeat("w", 32), "visible", moderation.Cache)
	if err != nil {
		t.Fatal(err)
	}
	store, err := NewSportsStore(db, wire, &SelectionProjection{DB: db}, map[string]string{"SPORTS_FEED_MODE": "visible", "WIRE_CURSOR_HMAC_SECRET": strings.Repeat("s", 32)})
	if err != nil {
		t.Fatal(err)
	}
	store.Remote = remote
	first, err := store.Page(context.Background(), "", 1, "en", "", false, now, "sports", nil)
	if err != nil || len(first.Items) != 1 || first.Items[0].Story.ItemID != "first" || first.Cursor == nil {
		t.Fatal("nonempty lean firstpage failed to persist", first, err)
	}
	reused, err := store.Page(context.Background(), "", 1, "en", "", false, now, "sports", nil)
	if err != nil || reused.GenerationID != first.GenerationID || len(reused.Items) != 1 || reused.Items[0].Story.ItemID != "first" {
		t.Fatal("warm lean reuse", reused, err)
	}
	// Emulate precisely the task-created persisted shape, without touching any
	// hosted rows. Keep its ID, ordinals, scopes, revision and expiry unchanged.
	if _, err := db.Exec(`UPDATE sports_personalized_snapshots SET payload=(SELECT jsonb_agg(jsonb_set(jsonb_set(value,'{item,reasons}','null'::jsonb),'{item,provenance}','null'::jsonb) ORDER BY ordinal) FROM jsonb_array_elements(payload)WITH ORDINALITY item(value,ordinal)) WHERE snapshot_id=$1::uuid`, first.GenerationID); err != nil {
		t.Fatal(err)
	}
	var beforeVersion string
	if err := db.QueryRow(`SELECT xmin::text FROM sports_personalized_snapshots WHERE snapshot_id=$1::uuid`, first.GenerationID).Scan(&beforeVersion); err != nil {
		t.Fatal(err)
	}
	compat, err := store.Page(context.Background(), *first.Cursor, 1, "en", "", false, now, "sports", nil)
	if err != nil || compat.GenerationID != first.GenerationID || len(compat.Items) != 1 || compat.Items[0].Story.ItemID != "second" || compat.Cursor == nil {
		t.Fatal("task row lost cursor/order", compat, err)
	}
	var afterVersion string
	if err := db.QueryRow(`SELECT xmin::text FROM sports_personalized_snapshots WHERE snapshot_id=$1::uuid`, first.GenerationID).Scan(&afterVersion); err != nil || afterVersion != beforeVersion {
		t.Fatal("compatibility reader rewrote row", err)
	}
	// The persistence conflict reader also encounters the original malformed
	// row; normalization must preserve its canonical snapshot identity.
	scope := mustHash(t, store.Hasher, "anonymous-sports") + ":sports"
	source := corpuscore.SportsSourceGeneration(remote.response)
	proposal := source
	proposal.GenerationID = "cccccccc-4444-4444-4444-444444444444"
	persisted, err := store.persist(context.Background(), proposal, source, scope, first.PreferenceRevision, now)
	if err != nil || persisted.GenerationID != first.GenerationID || persisted.Candidates[0].Item.ItemID != "first" {
		t.Fatal("conflict compatibility", persisted, err)
	}
	if _, err := db.Exec(`UPDATE sports_personalized_snapshots SET payload=(SELECT jsonb_agg(value-'presentationFingerprint' ORDER BY ordinal) FROM jsonb_array_elements(payload)WITH ORDINALITY item(value,ordinal)) WHERE snapshot_id=$1::uuid`, first.GenerationID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Page(context.Background(), *first.Cursor, 1, "en", "", false, now, "sports", nil); !errors.Is(err, corpuscore.ErrContractMismatch) {
		t.Fatal("legacy malformed null collections accepted", err)
	}
}
