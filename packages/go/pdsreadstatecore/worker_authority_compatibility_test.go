package pdsreadstatecore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	r "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
	"os"
	"testing"
	"time"
)

// Only the explicit revision/parity-confirmed API can activate first authority.
// Production worker reconciliation must preserve the original nil-revision fence.
func TestWorkerActivationCannotCreateFirstAuthority(t *testing.T) {
	dsn := os.Getenv("SOCIALWIRE_GO_READSTATE_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("isolated canonical PostgreSQL required")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:worker-authority-%d", time.Now().UnixNano())
	t.Cleanup(func() { db.Exec(`DELETE FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewer) })
	manifest := r.Manifest{Type: r.ManifestCollection, Version: 1, Generation: "first", LastSequence: 0}
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	cid, err := r.RecordCID(raw)
	if err != nil {
		t.Fatal(err)
	}
	store := Store{DB: db}
	if err := store.activate(ctx, viewer, manifest, cid, raw, nil); !errors.Is(err, sql.ErrNoRows) {
		t.Fatal("worker created missing authority", err)
	}
	var count int
	if err := db.QueryRow(`SELECT count(*) FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewer).Scan(&count); err != nil || count != 0 {
		t.Fatal("worker inserted first authority", count, err)
	}
	if _, err := db.Exec(`INSERT INTO appview_pds_read_state_authority(viewer_did,legacy_revision,projection_ready)VALUES($1,9,FALSE)`, viewer); err != nil {
		t.Fatal(err)
	}
	if err := store.activate(ctx, viewer, manifest, cid, raw, nil); !errors.Is(err, ErrStaleGeneration) {
		t.Fatal("worker bypassed explicit legacy parity", err)
	}
	var ready bool
	var revision int64
	var storedCID sql.NullString
	if err := db.QueryRow(`SELECT projection_ready,legacy_revision,manifest_cid FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewer).Scan(&ready, &revision, &storedCID); err != nil || ready || revision != 9 || storedCID.Valid {
		t.Fatal("worker changed legacy authority", ready, revision, storedCID, err)
	}
}
