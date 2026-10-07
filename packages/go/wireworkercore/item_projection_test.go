package wireworkercore

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func TestItemProjectionPreservesHigherPriorityAndMetadataRecovery(t *testing.T) {
	db := generationDatabase(t)
	ctx := context.Background()
	id, _ := newGenerationID()
	identity := wirecore.Canonicalize("https://" + id + ".example/article")
	at := time.Now().UTC().Truncate(time.Microsecond)
	summary := "Authoritative summary"
	t.Cleanup(func() { _, _ = db.Exec(`DELETE FROM wire_items WHERE canonical_key=$1`, identity.CanonicalKey) })
	apply := func(item ItemProjection) {
		tx, err := db.BeginTx(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback()
		if err = UpsertProjectedItem(ctx, tx, item, at); err != nil {
			t.Fatal(err)
		}
		if err = tx.Commit(); err != nil {
			t.Fatal(err)
		}
	}
	item := ItemProjection{Identity: *identity, RepresentativeURI: "at://did:example:a/site.standard.document/r", Host: id + ".example", SourceName: "Publication", Title: "Authoritative title", Language: "en", PresentationSource: "standard_site", PresentationPriority: 400, InspectionURL: identity.CanonicalURL, Summary: &summary, Confidence: .9, TargetKind: wirecore.StandardSiteDocument, Provenance: []string{"standard_site"}, RecordsActivity: false}
	apply(item)
	low := item
	low.Title = "A shared link"
	low.PresentationPriority = 100
	low.PresentationSource = "fallback"
	low.Language = "und"
	low.TargetKind = wirecore.ExternalArticle
	low.Provenance = []string{"direct_share"}
	low.Confidence = .6
	apply(low)
	var title, language, kind string
	var signal sql.NullTime
	if err := db.QueryRow(`SELECT title,language_code,target_kind,last_signal_at FROM wire_items WHERE canonical_key=$1`, identity.CanonicalKey).Scan(&title, &language, &kind, &signal); err != nil {
		t.Fatal(err)
	}
	if title != item.Title || language != "en" || kind != "standard_site_document" || signal.Valid {
		t.Fatalf("priority/activity mutated %s %s %s %#v", title, language, kind, signal)
	}
	if _, err := db.Exec(`DELETE FROM wire_link_metadata_cache WHERE canonical_key=$1`, identity.CanonicalKey); err != nil {
		t.Fatal(err)
	}
	apply(item)
	var exists bool
	if err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM wire_link_metadata_cache WHERE canonical_key=$1)`, identity.CanonicalKey).Scan(&exists); err != nil {
		t.Fatal(err)
	}
	if !exists {
		t.Fatal("unchanged item did not repair metadata seed")
	}
}
