package wireworkercore

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

type fixedVerifier struct {
	records map[string]VerifiedPublicRecord
}

func (v fixedVerifier) Verify(_ context.Context, uri string, cid *string) (PublicRecordVerification, error) {
	record, ok := v.records[uri]
	if !ok {
		return PublicRecordVerification{Status: "absent", ObservedAt: time.Now().UTC()}, nil
	}
	if cid != nil && *cid != record.CID {
		return PublicRecordVerification{Status: "changed", CID: record.CID, Revision: record.Revision, ObservedAt: record.ObservedAt}, nil
	}
	return PublicRecordVerification{Status: "verified", CID: record.CID, Revision: record.Revision, ObservedAt: record.ObservedAt, Record: &record}, nil
}
func TestHydrationProofSnapshotProjectionAndJournalWake(t *testing.T) {
	p, journal, generation, at, _ := recommendationFixture(t)
	ctx := context.Background()
	subject := "at://did:example:" + generation + "/site.standard.document/hydrated"
	event := claimFixture(t, p, generation, 2, "site.standard.graph.recommend", "create", map[string]any{"document": subject}, at.Add(time.Second))
	if _, err := p.DB.Exec(`UPDATE wire_ingestion_inbox SET repo_rev='2222222222222',record_cid='original' WHERE source_generation=$1 AND seq=2`, generation); err != nil {
		t.Fatal(err)
	}
	if outcome, err := p.ApplyClaimed(ctx, event, at.Add(time.Second)); err != nil || outcome != InboxDeferred {
		t.Fatalf("defer %s %v", outcome, err)
	}
	original, _ := json.Marshal(map[string]any{"$type": "site.standard.graph.recommend", "document": subject})
	document, _ := json.Marshal(map[string]any{"$type": "site.standard.document", "url": "https://" + generation + ".example/hydrated", "title": "Hydrated"})
	verifier := fixedVerifier{records: map[string]VerifiedPublicRecord{event.SourceURI(): {URI: event.SourceURI(), RepoDID: event.Repository.RepoDID, Collection: "site.standard.graph.recommend", RecordKey: "rkey", CID: "original", Revision: "2222222222222", PDSBase: "https://pds.example", Record: original, ObservedAt: at.Add(2 * time.Second)}, subject: {URI: subject, RepoDID: event.Repository.RepoDID, Collection: "site.standard.document", RecordKey: "hydrated", CID: "document", Revision: "2222222222222", PDSBase: "https://pds.example", Record: document, ObservedAt: at.Add(2 * time.Second)}}}
	hydrator := DependencyHydrator{Store: DependencyRecoveryStore{DB: p.DB, Environment: "dev"}, Verifier: verifier, Processor: p}
	t.Cleanup(func() {
		_, _ = p.DB.Exec(`DELETE FROM wire_ingestion_inbox WHERE source_generation=$1 AND repo_did=$2`, HydrationGeneration, event.Repository.RepoDID)
		_, _ = p.DB.Exec(`DELETE FROM wire_standard_record_fences WHERE source_generation=$1 AND source_uri=$2`, HydrationGeneration, subject)
	})
	counts, err := hydrator.Hydrate(ctx, at.Add(2*time.Second), 16)
	if err != nil {
		t.Fatal(err)
	}
	if counts.Verified != 1 || counts.Staged != 1 {
		t.Fatalf("hydrate %#v", counts)
	}
	var exists bool
	if err = p.DB.QueryRow(`SELECT EXISTS(SELECT 1 FROM wire_item_aliases WHERE alias_key=$1)`, subject).Scan(&exists); err != nil || !exists {
		t.Fatalf("alias %v %v", exists, err)
	}
	journal.DependencyVerification = true
	recovered, err := journal.Recover(ctx, at.Add(3*time.Second), 16, &InboxScope{Environment: "dev", Generations: []string{generation}})
	if err != nil {
		t.Fatal(err)
	}
	if recovered.Resolved != 1 {
		t.Fatalf("recovered %#v", recovered)
	}
}
