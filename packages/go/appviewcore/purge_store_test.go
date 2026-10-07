package appviewcore

import (
	"context"
	"fmt"
	"testing"
	"time"
)

func TestPurgeExplicitMarksPreservesOtherViewersAndFloors(t *testing.T) {
	db := fixtureDatabase(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:purge-%d", time.Now().UnixNano())
	other := viewer + "-other"
	t.Cleanup(func() {
		for _, table := range []string{"read_marks", "appview_unread_overrides", "appview_publication_read_floors"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=ANY($1)", []string{viewer, other})
		}
	})
	for _, did := range []string{viewer, other} {
		for _, table := range []string{"read_marks", "appview_unread_overrides"} {
			if _, err := db.Exec("INSERT INTO "+table+"(viewer_did,subject_uri,created_at) VALUES($1,'at://subject',now())", did); err != nil {
				t.Fatal(err)
			}
		}
	}
	if _, err := db.Exec(`INSERT INTO appview_publication_read_floors(viewer_did,publication_id,read_floor_at,generation) VALUES($1,'publication',now(),1)`, viewer); err != nil {
		t.Fatal(err)
	}
	if err := (ReadMutationStore{DB: db}).Purge(ctx, viewer); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"read_marks", "appview_unread_overrides"} {
		var own, foreign int
		if err := db.QueryRow("SELECT count(*) FILTER(WHERE viewer_did=$1),count(*) FILTER(WHERE viewer_did=$2) FROM "+table+" WHERE viewer_did=ANY($3)", viewer, other, []string{viewer, other}).Scan(&own, &foreign); err != nil || own != 0 || foreign != 1 {
			t.Fatal(table, own, foreign, err)
		}
	}
	var floors int
	if err := db.QueryRow(`SELECT count(*) FROM appview_publication_read_floors WHERE viewer_did=$1`, viewer).Scan(&floors); err != nil || floors != 1 {
		t.Fatal("floors removed", floors, err)
	}
}
