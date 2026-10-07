package wireworkercore

import (
	"context"
	"testing"
	"time"
)

func TestTerminalCleanupRequiresJournalHandoffAndAdjustsAdmission(t *testing.T) {
	p, generation, at := projectionFixture(t)
	repo := "did:example:" + generation
	for i, status := range []string{"applied", "dead_letter", "deferred", "pending"} {
		seedInbox(t, p.DB, generation, repo, int64(i+1), "pending", at, "app.bsky.feed.post", "create", `{}`)
		if _, err := p.DB.Exec(`UPDATE wire_ingestion_inbox SET status=$1,applied_at=CASE WHEN $1='applied' THEN $2::timestamptz ELSE NULL END,dead_lettered_at=CASE WHEN $1='dead_letter' THEN $2::timestamptz ELSE NULL END WHERE source_generation=$3 AND seq=$4`, status, at, generation, i+1); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := p.DB.Exec(`UPDATE wire_ingestion_inbox SET expires_at=$1 WHERE source_generation=$2`, at.Add(-time.Second), generation); err != nil {
		t.Fatal(err)
	}
	if _, err := p.DB.Exec(`INSERT INTO wire_ingestion_admission(environment,retained_rows,updated_at)VALUES('dev',4,$1)ON CONFLICT(environment)DO UPDATE SET retained_rows=wire_ingestion_admission.retained_rows+4`, at); err != nil {
		t.Fatal(err)
	}
	var before int
	if err := p.DB.QueryRow(`SELECT retained_rows FROM wire_ingestion_admission WHERE environment='dev'`).Scan(&before); err != nil {
		t.Fatal(err)
	}
	count, err := p.DeleteTerminal(context.Background(), at, 5000)
	if err != nil || count != 2 {
		t.Fatalf("cleanup %d %v", count, err)
	}
	var remaining int
	if err = p.DB.QueryRow(`SELECT count(*)FROM wire_ingestion_inbox WHERE source_generation=$1`, generation).Scan(&remaining); err != nil || remaining != 2 {
		t.Fatalf("handoff barrier %d %v", remaining, err)
	}
	var after int
	if err = p.DB.QueryRow(`SELECT retained_rows FROM wire_ingestion_admission WHERE environment='dev'`).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if after != max(0, before-2) {
		t.Fatalf("admission %d→%d", before, after)
	}
}
