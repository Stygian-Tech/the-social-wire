package pdsreadstatecore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	r "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
)

func TestPostgresReconcileIsAtomicAndVerifiesContent(t *testing.T) {
	dsn := os.Getenv("SOCIALWIRE_GO_READSTATE_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("local conformance database not configured")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	viewer := "did:plc:readstatefixture"
	subject := "at://did:plc:author/site.standard.document/one"
	for _, table := range []string{"appview_pds_read_state_exact", "appview_pds_read_state_boundaries", "appview_pds_read_state_authority"} {
		if _, err := db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		for _, table := range []string{"appview_pds_read_state_exact", "appview_pds_read_state_boundaries", "appview_pds_read_state_authority"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
	})
	base := r.Manifest{Type: r.ManifestCollection, Version: 1, Generation: "base", LastSequence: 0}
	baseJSON, _ := json.Marshal(base)
	baseCID, _ := r.RecordCID(baseJSON)
	if _, err := db.Exec(`INSERT INTO appview_pds_read_state_authority(viewer_did,manifest,manifest_cid,projection_ready,last_accessed_at) VALUES($1,$2::jsonb,$3,TRUE,NOW())`, viewer, string(baseJSON), baseCID); err != nil {
		t.Fatal(err)
	}
	chunk := r.Chunk{Type: r.ChunkCollection, Version: 1, Operations: []r.Operation{{ActionID: "action", Sequence: 1, State: r.Read, ActedAt: "2026-10-06T00:00:00Z", Selection: r.Exact, SubjectURIs: []string{subject}}}}
	chunkJSON, _ := json.Marshal(chunk)
	chunkCID, _ := r.RecordCID(chunkJSON)
	candidate := r.Manifest{Type: r.ManifestCollection, Version: 1, Generation: "next", LastSequence: 1, Head: &r.Reference{URI: "at://" + viewer + "/" + r.ChunkCollection + "/one", CID: chunkCID}}
	manifestJSON, _ := json.Marshal(candidate)
	manifestCID, _ := r.RecordCID(manifestJSON)
	badChunk := false
	changedManifest := false
	manifestCalls := 0
	s := Store{DB: db, FetchRecord: func(_ context.Context, did, collection, key string, _ *string) (string, string, []byte, error) {
		uri := "at://" + did + "/" + collection + "/" + key
		if collection == r.ManifestCollection {
			manifestCalls++
			if changedManifest && manifestCalls%2 == 0 {
				return uri, baseCID, baseJSON, nil
			}
			return uri, manifestCID, manifestJSON, nil
		}
		if badChunk {
			return uri, chunkCID, []byte(`{"changed":true}`), nil
		}
		return uri, chunkCID, chunkJSON, nil
	}}
	badChunk = true
	if _, err := s.Reconcile(ctx, viewer, true); err == nil {
		t.Fatal("accepted forged chunk")
	}
	var storedCID string
	db.QueryRow(`SELECT manifest_cid FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewer).Scan(&storedCID)
	if storedCID != baseCID {
		t.Fatal("failed load changed authority")
	}
	badChunk = false
	manifestCalls = 0
	changedManifest = true
	if _, err := s.Reconcile(ctx, viewer, true); !errors.Is(err, ErrStaleGeneration) {
		t.Fatal("accepted concurrent manifest", err)
	}
	changedManifest = false
	manifestCalls = 0
	if ok, err := s.Reconcile(ctx, viewer, true); err != nil || !ok {
		t.Fatal(ok, err)
	}
	var read bool
	if err := db.QueryRow(`SELECT is_read FROM appview_pds_read_state_exact WHERE viewer_did=$1 AND subject_uri=$2`, viewer, subject).Scan(&read); err != nil || !read {
		t.Fatal(read, err)
	}
	if ok, err := s.Reconcile(ctx, viewer, true); err != nil || !ok {
		t.Fatal("idempotent activation", err)
	}
	if _, err := db.Exec(`UPDATE appview_pds_read_state_authority SET last_accessed_at=$2 WHERE viewer_did=$1`, viewer, time.Now().Add(-30*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if got, deleted, more, err := s.EvictIdle(ctx, time.Now().Add(-7*24*time.Hour), time.Now(), 1); err != nil || got != viewer || deleted != 1 || !more {
		t.Fatal(got, deleted, more, err)
	}
	if _, err := s.IsRead(ctx, viewer, subject); !errors.Is(err, ErrProjectionUnavailable) {
		t.Fatal("eviction did not fail closed", err)
	}
	if ok, err := s.Reconcile(ctx, viewer, false); err != nil || ok {
		t.Fatal("rebuilt despite policy", err)
	}
	if ok, err := s.Reconcile(ctx, viewer, true); err != nil || !ok {
		t.Fatal("failed rebuild", ok, err)
	}
}

func TestTransitionRejectsRollback(t *testing.T) {
	revision := int64(8)
	previous := r.Manifest{Version: 2, LastSequence: 4, Revision: &revision}
	for _, candidate := range []r.Manifest{{Version: 1, LastSequence: 9}, {Version: 2, LastSequence: 3, Revision: &revision}, previous} {
		if validateTransition(previous, "one", candidate, "two") == nil {
			t.Fatal("accepted rollback", candidate)
		}
	}
}
