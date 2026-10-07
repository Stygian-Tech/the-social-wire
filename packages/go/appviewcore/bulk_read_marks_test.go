package appviewcore

import (
	"context"
	"fmt"
	"testing"
	"time"
)

func TestBulkReadMarksRollBackWhenLaterChunkFails(t *testing.T) {
	db := fixtureDatabase(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:bulk%d", time.Now().UnixNano())
	t.Cleanup(func() {
		db.Exec(`DELETE FROM read_marks WHERE viewer_did=$1`, viewer)
		db.Exec(`DELETE FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewer)
	})
	subjects := []string{}
	for i := 0; i < 500; i++ {
		subjects = append(subjects, fmt.Sprintf("at://did:plc:author/site.standard.document/a%03d", i))
	}
	subjects = append(subjects, "z\x00invalid-postgres-text")
	if err := (ReadMutationStore{DB: db}).PutMany(ctx, viewer, subjects, time.Now()); err == nil {
		t.Fatal("invalid later chunk accepted")
	}
	var count int
	if err := db.QueryRow(`SELECT count(*) FROM read_marks WHERE viewer_did=$1`, viewer).Scan(&count); err != nil || count != 0 {
		t.Fatalf("partial bulk transaction committed: %d %v", count, err)
	}
	if err := (ReadMutationStore{DB: db}).PutMany(ctx, viewer, subjects[:500], time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`SELECT count(*) FROM read_marks WHERE viewer_did=$1`, viewer).Scan(&count); err != nil || count != 500 {
		t.Fatalf("valid bulk mutation: %d %v", count, err)
	}
}
