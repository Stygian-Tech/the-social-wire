package wireworkercore

import (
	"context"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func TestMetadataHTMLPrecedenceAndLanguageEvidence(t *testing.T) {
	data := []byte(`<html lang="es"><head><title>Fallback</title><meta property="og:title" content="The new article and how it works"><meta property="og:image" content="../art.jpg"><meta property="og:locale" content="en_US"><script type="application/ld+json">{"@graph":[{"@type":"NewsArticle","headline":"JSON title","inLanguage":"English","author":{"name":"Sam"},"publisher":{"name":"Wire","logo":{"url":"/icon.png"}},"datePublished":"2026-10-06T00:00:00Z"},{"@type":"Product"}]}</script></head></html>`)
	m, err := parseMetadataHTML(data, "https://publisher.example/posts/one")
	if err != nil || m == nil || optionalText(m.Title) != "The new article and how it works" || optionalText(m.ImageURL) != "https://publisher.example/art.jpg" || optionalText(m.IconURL) != "https://publisher.example/icon.png" || optionalText(m.AuthorName) != "Sam" || !m.ProductOffer || optionalText(m.Language) != "en" || m.PublishedAt == nil {
		t.Fatal(m, err)
	}
	if optionalText(validatedPageLanguage(m.Language, m.Title, m.Description)) != "en" {
		t.Fatal("lost supported language evidence")
	}
	wrong := "es"
	if validatedPageLanguage(&wrong, m.Title, m.Description) != nil {
		t.Fatal("accepted contradicted page language")
	}
	if m, err := parseMetadataHTML([]byte(`<html><head></head></html>`), "https://publisher.example/"); err != nil || m != nil {
		t.Fatal("invented metadata", m, err)
	}
}

func TestMetadataMaintenanceIsFencedAndSchedulingRequiresParity(t *testing.T) {
	db := generationDatabase(t)
	ctx := context.Background()
	id, _ := newGenerationID()
	role := "metadata-fixture-" + id
	leases := operationscore.PostgresRoleLeaseStore{DB: db, Environment: "dev"}
	lease, err := leases.Acquire(ctx, role, "fixture", time.Minute)
	if err != nil || lease == nil {
		t.Fatal(lease, err)
	}
	t.Cleanup(func() {
		db.Exec(`DELETE FROM operations_role_leases WHERE environment='dev' AND role=$1`, role)
		db.Exec(`SELECT wire_metadata_schedule_set_tracking(FALSE)`)
	})
	store := MetadataStore{DB: db, SchedulingRead: true}
	if _, err := store.Repair(ctx, &lease.RoleLeaseAuthority, time.Now(), 1); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`SELECT wire_metadata_schedule_set_tracking(TRUE)`); err != nil {
		t.Fatal(err)
	}
	if err := store.MaintainScheduling(ctx, &lease.RoleLeaseAuthority, time.Now()); err != nil {
		t.Fatal(err)
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	ready, err := store.schedulingReady(ctx, tx)
	tx.Rollback()
	if err != nil || !ready {
		t.Fatal(ready, err)
	}
	host := EnrichmentHost{DB: db}
	if _, err := host.healthBatch(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, _, err := host.pruneMetadata(ctx, time.Now(), nil); err != nil {
		t.Fatal(err)
	}
	if err := leases.Release(ctx, lease.RoleLeaseAuthority); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Repair(ctx, &lease.RoleLeaseAuthority, time.Now(), 1); err == nil {
		t.Fatal("released owner repaired metadata")
	}
}

func TestMetadataClaimFencePreservesPublisherAndRejectsOldOwner(t *testing.T) {
	db := generationDatabase(t)
	ctx := context.Background()
	id, _ := newGenerationID()
	identity := wirecore.Canonicalize("https://" + id + ".example/article")
	at := time.Now().UTC().Truncate(time.Microsecond)
	t.Cleanup(func() {
		db.Exec(`DELETE FROM wire_link_metadata_cache WHERE canonical_key=$1`, identity.CanonicalKey)
		db.Exec(`DELETE FROM wire_items WHERE canonical_key=$1`, identity.CanonicalKey)
	})
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	item := ItemProjection{Identity: *identity, RepresentativeURI: "at://did:example:a/site.standard.document/r", Host: id + ".example", SourceName: "Publication", Title: "Publisher Title", Language: "en", PresentationSource: "standard_site", PresentationPriority: 400, InspectionURL: identity.CanonicalURL, Confidence: .9, TargetKind: wirecore.StandardSiteDocument, Provenance: []string{"standard_site"}}
	if err := UpsertProjectedItem(ctx, tx, item, at); err != nil {
		tx.Rollback()
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	store := MetadataStore{DB: db}
	targets, err := store.Claim(ctx, 250, at)
	if err != nil {
		t.Fatal(err)
	}
	var target *MetadataTarget
	for _, candidate := range targets {
		if candidate.Key == identity.CanonicalKey {
			copy := candidate
			target = &copy
		}
	}
	if target == nil {
		t.Fatal("fixture not claimed")
	}
	renewed, err := store.Renew(ctx, *target, at)
	if err != nil || renewed == nil {
		t.Fatal(renewed, err)
	}
	metadata := LinkMetadata{URL: identity.CanonicalURL, Title: stringPointer("Open Graph Title"), ImageURL: stringPointer("https://publisher.example/art.jpg")}
	if err := store.Save(ctx, *target, metadata, at); err != nil {
		t.Fatal(err)
	}
	var cacheTitle *string
	if err := db.QueryRow(`SELECT title FROM wire_link_metadata_cache WHERE canonical_key=$1`, identity.CanonicalKey).Scan(&cacheTitle); err != nil {
		t.Fatal(err)
	}
	if optionalText(cacheTitle) == "Open Graph Title" {
		t.Fatal("stale owner changed cache")
	}
	if err := store.Save(ctx, *renewed, metadata, at); err != nil {
		t.Fatal(err)
	}
	var title, image string
	if err := db.QueryRow(`SELECT title,thumbnail_url FROM wire_items WHERE canonical_key=$1`, identity.CanonicalKey).Scan(&title, &image); err != nil {
		t.Fatal(err)
	}
	if title != "Publisher Title" || image != *metadata.ImageURL {
		t.Fatal("publisher precedence lost", title, image)
	}
	if err := store.Failure(ctx, *target, true, at); err != nil {
		t.Fatal(err)
	}
	var status string
	if err := db.QueryRow(`SELECT status FROM wire_link_metadata_cache WHERE canonical_key=$1`, identity.CanonicalKey).Scan(&status); err != nil || status != "fresh" {
		t.Fatal(status, err)
	}
}
