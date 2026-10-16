package appviewcore

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
)

func TestBulkReadFencesNewerUnreadAndPreservesReplayMetadata(t *testing.T) {
	db := fixtureDatabase(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:bulk-fence-%d", time.Now().UnixNano())
	author := viewer + "-author"
	publication := "at://" + author + "/site.standard.publication/main"
	at := time.Now().UTC().Truncate(time.Second)
	later := at.Add(2 * time.Second)
	t.Cleanup(func() {
		for _, table := range []string{"read_marks", "appview_unread_overrides", "appview_unread_counters", "unread_counts_cache", "appview_publication_scopes", "appview_pds_read_state_authority"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
		db.Exec(`DELETE FROM content_items WHERE author_did=$1`, author)
	})
	execute := func(query string, args ...any) {
		t.Helper()
		if _, err := db.Exec(query, args...); err != nil {
			t.Fatal(err)
		}
	}
	subjects := []string{}
	for _, key := range []string{"protected", "older", "equal", "newer-read"} {
		subject := "at://" + author + "/site.standard.document/" + key
		subjects = append(subjects, subject)
		execute(`INSERT INTO content_items(uri,cid,author_did,collection,created_at,indexed_at,publication_site,render_json,expires_at) VALUES($1,'fixture',$2,'site.standard.document',$3,$3,$4,'{"title":"Article"}'::jsonb,$3::timestamptz+interval '1 hour')`, subject, author, at, publication)
	}
	execute(`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,publication_at_uri,scope_keys,updated_at) VALUES($1,$2,$3,$2,jsonb_build_array($2::text),$4)`, viewer, publication, author, at)
	execute(`INSERT INTO appview_unread_overrides(viewer_did,subject_uri,created_at) VALUES($1,$2,$5::timestamptz+interval '1 second'),($1,$3,$5::timestamptz-interval '1 second'),($1,$4,$5)`, viewer, subjects[0], subjects[1], subjects[2], at)
	execute(`INSERT INTO read_marks(viewer_did,subject_uri,created_at) VALUES($1,$2,$3)`, viewer, subjects[3], later)
	generation := later.UnixMilli()
	execute(`INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at) VALUES($1,$2,3,$3,'exact',FALSE,$4)`, viewer, publication, generation, later)
	execute(`INSERT INTO unread_counts_cache(viewer_did,publication_id,unread_count,expires_at) VALUES($1,$2,3,$3::timestamptz+interval '1 hour')`, viewer, publication, at)
	store := ReadMutationStore{DB: db}
	for attempt := 0; attempt < 2; attempt++ {
		applied, err := store.PutMany(ctx, viewer, append(subjects, subjects[1]), at)
		want := []string{subjects[2], subjects[3], subjects[1]}
		if err != nil || !reflect.DeepEqual(applied, want) {
			t.Fatalf("attempt %d confirmed wrong IDs: %v error=%v", attempt, applied, err)
		}
		var protectedUnread, protectedRead bool
		if err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM appview_unread_overrides WHERE viewer_did=$1 AND subject_uri=$2),EXISTS(SELECT 1 FROM read_marks WHERE viewer_did=$1 AND subject_uri=$2)`, viewer, subjects[0]).Scan(&protectedUnread, &protectedRead); err != nil || !protectedUnread || protectedRead {
			t.Fatalf("newer unread was overwritten: unread=%v read=%v error=%v", protectedUnread, protectedRead, err)
		}
		var readAt time.Time
		if err := db.QueryRow(`SELECT created_at FROM read_marks WHERE viewer_did=$1 AND subject_uri=$2`, viewer, subjects[3]).Scan(&readAt); err != nil || !readAt.Equal(later) {
			t.Fatalf("replay backdated a newer read: %v error=%v", readAt, err)
		}
		var count, cached, overrides int
		var gotGeneration int64
		var dirty bool
		var accuracy string
		var countedAt time.Time
		if err := db.QueryRow(`SELECT unread_count,generation,accuracy,dirty,counted_at FROM appview_unread_counters WHERE viewer_did=$1 AND publication_id=$2`, viewer, publication).Scan(&count, &gotGeneration, &accuracy, &dirty, &countedAt); err != nil || count != 3 || gotGeneration != generation || !dirty || accuracy != "estimated" || !countedAt.Equal(later) {
			t.Fatalf("counter freshness regressed: count=%d generation=%d accuracy=%s dirty=%v at=%v error=%v", count, gotGeneration, accuracy, dirty, countedAt, err)
		}
		if err := db.QueryRow(`SELECT COUNT(*) FROM unread_counts_cache WHERE viewer_did=$1`, viewer).Scan(&cached); err != nil || cached != 0 {
			t.Fatalf("stale exact cache survived: %d %v", cached, err)
		}
		if err := db.QueryRow(`SELECT COUNT(*) FROM appview_unread_overrides WHERE viewer_did=$1`, viewer).Scan(&overrides); err != nil || overrides != 1 {
			t.Fatalf("old/equal overrides were not consumed: %d %v", overrides, err)
		}
		actual, err := (ContentReader{DB: db}).ScopedUnreadCount(ctx, viewer, PublicationScope{AuthorDID: author, PublicationATURI: &publication}, at)
		if err != nil || actual != 1 {
			t.Fatalf("authoritative count lost the newer unread: %d %v", actual, err)
		}
	}
}

func TestBulkReadWaitsForConcurrentNewerUnreadCommit(t *testing.T) {
	db := fixtureDatabase(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	viewer := fmt.Sprintf("did:plc:bulk-lock-%d", time.Now().UnixNano())
	subject := "at://did:plc:fixture/site.standard.document/" + viewer
	at := time.Now().UTC().Truncate(time.Second)
	t.Cleanup(func() {
		for _, table := range []string{"read_marks", "appview_unread_overrides", "appview_pds_read_state_authority"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
	})
	config, err := pgx.ParseConfig(os.Getenv("SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	config.RuntimeParams["application_name"] = viewer
	worker := sql.OpenDB(stdlib.GetConnector(*config))
	defer worker.Close()
	store := ReadMutationStore{DB: worker}
	if err := store.Put(ctx, viewer, subject, true, at.Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	guard, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer guard.Rollback()
	if _, err := guard.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1 || '|' || $2,150))`, viewer, subject); err != nil {
		t.Fatal(err)
	}
	waitForBlocked := func(want int) {
		t.Helper()
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			var blocked int
			if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM pg_stat_activity WHERE application_name=$1 AND wait_event_type='Lock'`, viewer).Scan(&blocked); err != nil {
				t.Fatal(err)
			}
			if blocked == want {
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
		t.Fatal("mutation did not reach the controlled lock boundary")
	}
	unreadDone := make(chan error, 1)
	go func() { unreadDone <- store.Put(ctx, viewer, subject, false, at.Add(time.Second)) }()
	waitForBlocked(1) // Single unread owns the authority row, waiting on its subject.
	bulkDone := make(chan error, 1)
	go func() {
		applied, err := store.PutMany(ctx, viewer, []string{subject}, at)
		if err == nil && len(applied) != 0 {
			err = fmt.Errorf("stale bulk confirmed %d protected subjects", len(applied))
		}
		bulkDone <- err
	}()
	waitForBlocked(2) // Bulk must wait for that unread transaction to commit.
	if err := guard.Commit(); err != nil {
		t.Fatal(err)
	}
	for _, done := range []<-chan error{unreadDone, bulkDone} {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
	var unread, read bool
	if err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM appview_unread_overrides WHERE viewer_did=$1 AND subject_uri=$2),EXISTS(SELECT 1 FROM read_marks WHERE viewer_did=$1 AND subject_uri=$2)`, viewer, subject).Scan(&unread, &read); err != nil || !unread || read {
		t.Fatalf("concurrent newer unread lost: unread=%v read=%v error=%v", unread, read, err)
	}
}
