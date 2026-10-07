package pdsreadstatecore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	r "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
)

func TestLegacyExportAndVerifiedFirstMigration(t *testing.T) {
	dsn := os.Getenv("SOCIALWIRE_GO_READSTATE_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires isolated canonical PostgreSQL")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	viewer := fmt.Sprintf("did:plc:export%d", time.Now().UnixNano())
	ctx := context.Background()
	at := time.Now().UTC().Truncate(time.Millisecond)
	subjects := []string{"at://did:plc:author/site.standard.document/unread", "at://did:plc:author/site.standard.document/read"}
	t.Cleanup(func() {
		for _, table := range []string{"appview_pds_read_state_exact", "appview_pds_read_state_boundaries", "appview_pds_read_state_authority", "read_marks", "appview_unread_overrides", "appview_pds_read_state_authority"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
	})
	if _, err := db.Exec(`INSERT INTO appview_unread_overrides(viewer_did,subject_uri,created_at) VALUES($1,$2,$3)`, viewer, subjects[0], at); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO read_marks(viewer_did,subject_uri,created_at) VALUES($1,$2,$3)`, viewer, subjects[1], at); err != nil {
		t.Fatal(err)
	}
	store := Store{DB: db}
	page, err := store.Export(ctx, viewer, nil, nil, 1)
	if err != nil || len(page.Rows) != 1 || page.Rows[0].Kind != "unread" || page.Cursor == nil {
		t.Fatalf("bad first export: %#v %v", page, err)
	}
	if _, err := store.Export(ctx, viewer, page.Cursor, nil, 1); !errors.Is(err, ErrInvalidCursor) {
		t.Fatalf("continuation accepted without revision: %v", err)
	}
	wrong := page.LegacyRevision + 1
	if _, err := store.Export(ctx, viewer, page.Cursor, &wrong, 1); !errors.Is(err, ErrRevisionChanged) {
		t.Fatalf("stale continuation accepted: %v", err)
	}
	second, err := store.Export(ctx, viewer, page.Cursor, &page.LegacyRevision, 1)
	if err != nil || len(second.Rows) != 1 || second.Rows[0].Kind != "read" || second.Cursor != nil {
		t.Fatalf("bad second export: %#v %v", second, err)
	}
	operations := []r.Operation{
		{ActionID: "first", Sequence: 1, State: r.Unread, ActedAt: page.Rows[0].ActedAt, Selection: r.Exact, SubjectURIs: []string{subjects[0]}},
		{ActionID: "second", Sequence: 2, State: r.Read, ActedAt: second.Rows[0].ActedAt, Selection: r.Exact, SubjectURIs: []string{subjects[1]}},
	}
	chunk := r.Chunk{Type: r.ChunkCollection, Version: 1, Operations: operations}
	chunkJSON, _ := json.Marshal(chunk)
	chunkCID, err := r.RecordCID(chunkJSON)
	if err != nil {
		t.Fatal(err)
	}
	manifest := r.Manifest{Type: r.ManifestCollection, Version: 1, Generation: "migration", LastSequence: 2, Head: &r.Reference{URI: "at://" + viewer + "/" + r.ChunkCollection + "/first", CID: chunkCID}}
	manifestJSON, _ := json.Marshal(manifest)
	manifestCID, err := r.RecordCID(manifestJSON)
	if err != nil {
		t.Fatal(err)
	}
	store.FetchRecord = func(_ context.Context, did, collection, key string, _ *string) (string, string, []byte, error) {
		uri := "at://" + did + "/" + collection + "/" + key
		if collection == r.ManifestCollection {
			return uri, manifestCID, manifestJSON, nil
		}
		return uri, chunkCID, chunkJSON, nil
	}
	if _, err := store.Confirm(ctx, viewer, manifestCID, &wrong); !errors.Is(err, ErrRevisionChanged) {
		t.Fatalf("stale first activation accepted: %v", err)
	}
	status, err := store.Confirm(ctx, viewer, manifestCID, &page.LegacyRevision)
	if err != nil || status.Authority != "pds" || status.ManifestCID == nil || *status.ManifestCID != manifestCID {
		t.Fatalf("first verified migration failed: %#v %v", status, err)
	}
	if _, err := store.Export(ctx, viewer, nil, nil, 100); !errors.Is(err, ErrAlreadyMigrated) {
		t.Fatalf("export allowed after migration: %v", err)
	}
	if _, err := store.Confirm(ctx, viewer, manifestCID, nil); err != nil {
		t.Fatalf("idempotent confirmation failed: %v", err)
	}
}

func TestStrictLegacyExportCursor(t *testing.T) {
	for _, raw := range []string{"", "not-base64", "e30=", "eyJwaGFzZSI6Mywia2V5IjoiYSJ9", "eyJwaGFzZSI6MSwia2V5IjoxfQ=="} {
		if _, err := decodeExportPosition(&raw); !errors.Is(err, ErrInvalidCursor) {
			t.Errorf("accepted invalid export cursor %q: %v", raw, err)
		}
	}
}
