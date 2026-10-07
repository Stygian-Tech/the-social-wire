package thinappviewcore

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"testing"
	"time"
)

func TestSelectionMutationIdentity(t *testing.T) {
	at := time.Now()
	for _, topic := range []string{"finance", "sports"} {
		value := "instrument"
		field := "kind"
		identity := "instrument:fin_fixture"
		if topic == "sports" {
			value = "follow"
			field = "action"
			identity = "fin_fixture"
		}
		hash := sha256.Sum256([]byte(identity))
		key := hex.EncodeToString(hash[:])
		record := map[string]any{"$type": "app.thesocialwire." + topic + ".selection", field: value, "reference": "fin_fixture"}
		if ParseSelectionMutation(topic, "did:plc:viewer", key, "create", record, at, "rev") == nil {
			t.Fatal("valid selection rejected")
		}
		record["reference"] = "other"
		if ParseSelectionMutation(topic, "did:plc:viewer", key, "create", record, at, "rev") != nil {
			t.Fatal("identity/key mismatch accepted")
		}
		if ParseSelectionMutation(topic, "did:plc:viewer", key, "delete", nil, at, "rev") == nil {
			t.Fatal("delete must not require record")
		}
	}
}
func TestPostgresSelectionRejectsStaleEventsAndSync(t *testing.T) {
	db := inboxDatabase(t)
	ctx := context.Background()
	store := SelectionStore{DB: db}
	nonce, err := inboxLeaseToken()
	if err != nil {
		t.Fatal(err)
	}
	viewer := "did:plc:selection" + nonce
	at := time.Now().UTC().Truncate(time.Microsecond)
	for _, topic := range []string{"finance", "sports"} {
		t.Run(topic, func(t *testing.T) {
			t.Cleanup(func() {
				for _, table := range []string{"selections", "selection_versions", "selection_sync"} {
					db.Exec(fmt.Sprintf("DELETE FROM %s_%s WHERE viewer_did=$1", topic, table), viewer)
				}
			})
			value := "instrument"
			if topic == "sports" {
				value = "follow"
			}
			ref := "fixture"
			key := nonce
			mutation := SelectionMutation{Topic: topic, ViewerDID: viewer, RecordKey: key, RepoRev: "002", EventAt: at, Value: &value, Reference: &ref}
			if err := store.Apply(ctx, mutation); err != nil {
				t.Fatal(err)
			}
			stale := mutation
			stale.Value = nil
			stale.Reference = nil
			stale.RepoRev = "001"
			if err := store.Apply(ctx, stale); err != nil {
				t.Fatal(err)
			}
			var count int
			if err := db.QueryRow(fmt.Sprintf("SELECT count(*) FROM %s_selections WHERE viewer_did=$1", topic), viewer).Scan(&count); err != nil {
				t.Fatal(err)
			}
			if count != 1 {
				t.Fatal("stale same-time delete erased selection")
			}
			newer := stale
			newer.EventAt = at.Add(time.Second)
			if err := store.Apply(ctx, newer); err != nil {
				t.Fatal(err)
			}
			if err := db.QueryRow(fmt.Sprintf("SELECT count(*) FROM %s_selections WHERE viewer_did=$1", topic), viewer).Scan(&count); err != nil {
				t.Fatal(err)
			}
			if count != 0 {
				t.Fatal("newer delete did not apply")
			}
			if _, err := db.Exec(fmt.Sprintf("INSERT INTO %s_selection_sync(viewer_did,synced_at) VALUES($1,$2)", topic), viewer, at.Add(5*time.Second)); err != nil {
				t.Fatal(err)
			}
			mutation.EventAt = at.Add(4 * time.Second)
			mutation.RepoRev = "999"
			if err := store.Apply(ctx, mutation); err != nil {
				t.Fatal(err)
			}
			if err := db.QueryRow(fmt.Sprintf("SELECT count(*) FROM %s_selections WHERE viewer_did=$1", topic), viewer).Scan(&count); err != nil {
				t.Fatal(err)
			}
			if count != 0 {
				t.Fatal("event older than full sync must not resurrect selection")
			}

		})
	}
}
