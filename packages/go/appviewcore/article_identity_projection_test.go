package appviewcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
)

func TestArticleIdentityProjectionBackfillAndConcurrentMaintenance(t *testing.T) {
	admin := fixtureDatabase(t)
	dsn := os.Getenv("SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL")
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	if (config.Host != "127.0.0.1" && config.Host != "localhost" && config.Host != "::1") ||
		(config.Database != "socialwire_go_test" && !strings.HasPrefix(config.Database, "tsw")) {
		t.Fatal("migration regression requires a disposable loopback database")
	}
	if _, err := exec.LookPath("psql"); err != nil {
		t.Fatal("migration regression requires psql")
	}
	schema := fmt.Sprintf("article_identity_test_%d", time.Now().UnixNano())
	if _, err := admin.Exec("CREATE SCHEMA " + schema); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { admin.Exec("DROP SCHEMA " + schema + " CASCADE") })
	config.RuntimeParams["search_path"] = schema + ",public"
	db := sql.OpenDB(stdlib.GetConnector(*config))
	t.Cleanup(func() { db.Close() })
	execute := func(query string, args ...any) {
		t.Helper()
		if _, err := db.Exec(query, args...); err != nil {
			t.Fatal(err)
		}
	}
	execute(`CREATE TABLE content_items (LIKE public.content_items INCLUDING ALL)`)
	source, err := os.ReadFile(filepath.Join("..", "..", "..", "database", "migrations", "20261016080000_content_item_article_identities.sql"))
	if err != nil {
		t.Fatal(err)
	}
	migration := string(source)
	backfillStart := strings.Index(migration, "-- Commit each small keyset batch.")
	if backfillStart < 0 || !strings.Contains(migration, "PERFORM pg_sleep(0.01);") {
		t.Fatal("migration backfill boundary changed; update interruption fixture")
	}
	runSQL := func(body, application string) ([]byte, error) {
		file, err := os.CreateTemp(t.TempDir(), "migration-*.sql")
		if err != nil {
			return nil, err
		}
		_, err = file.WriteString("SET search_path TO " + schema + ",public;\nSET application_name TO '" + application + "';\n" + body)
		closeErr := file.Close()
		if err != nil {
			return nil, err
		}
		if closeErr != nil {
			return nil, closeErr
		}
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		return exec.CommandContext(ctx, "psql", dsn, "-X", "-v", "ON_ERROR_STOP=1", "-f", file.Name()).CombinedOutput()
	}
	uri := func(i int) string { return fmt.Sprintf("at://did:plc:identity/site.standard.document/%04d", i) }
	execute(`INSERT INTO content_items(uri,cid,author_did,collection,created_at,indexed_at,render_json,expires_at)
 SELECT 'at://did:plc:identity/site.standard.document/'||lpad(i::text,4,'0'),'fixture','did:plc:identity','site.standard.document',NOW(),NOW(),jsonb_build_object('title','Article','articleUrl','https://fixture.invalid/'||i),NOW()+interval '1 hour' FROM generate_series(1,600)i`)
	interrupted := strings.Replace(migration, "PERFORM pg_sleep(0.01);", "RAISE EXCEPTION 'simulated backfill interruption';", 1)
	output, err := runSQL(interrupted, schema+"_partial")
	if err == nil || !strings.Contains(string(output), "simulated backfill interruption") {
		t.Fatalf("expected interruption after committed batch: %v %s", err, output)
	}
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM content_item_article_identities`).Scan(&count); err != nil || count != 512 {
		t.Fatalf("committed prefix lost: count=%d error=%v", count, err)
	}
	if output, err := runSQL(migration, schema+"_retry"); err != nil {
		t.Fatalf("retry: %v %s", err, output)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM content_item_article_identities`).Scan(&count); err != nil || count != 600 {
		t.Fatalf("retry omitted source rows: count=%d error=%v", count, err)
	}
	var before string
	if err := db.QueryRow(`SELECT xmin::text FROM content_item_article_identities WHERE uri=$1`, uri(1)).Scan(&before); err != nil {
		t.Fatal(err)
	}
	if output, err := runSQL(migration, schema+"_repeat"); err != nil {
		t.Fatalf("idempotent rerun: %v %s", err, output)
	}
	var after string
	if err := db.QueryRow(`SELECT xmin::text FROM content_item_article_identities WHERE uri=$1`, uri(1)).Scan(&after); err != nil || before != after {
		t.Fatalf("rerun rewrote an existing identity: before=%s after=%s error=%v", before, after, err)
	}
	assertKey := func(subject, expected string) {
		t.Helper()
		var key string
		if err := db.QueryRow(`SELECT article_key FROM content_item_article_identities WHERE uri=$1`, subject).Scan(&key); err != nil || key != expected {
			t.Fatalf("identity mismatch for %s: got length=%d expected length=%d error=%v", subject, len(key), len(expected), err)
		}
	}
	largeURL := "https://fixture.invalid/" + strings.Repeat("large", 4000)
	execute(`UPDATE content_items SET render_json=jsonb_build_object('title','Large','articleUrl',$2::text) WHERE uri=$1`, uri(1), largeURL)
	assertKey(uri(1), largeURL)
	execute(`UPDATE content_items SET render_json='{"title":"No URL","articleUrl":""}'::jsonb WHERE uri=$1`, uri(1))
	assertKey(uri(1), uri(1))
	execute(`UPDATE content_items SET render_json='{"title":"Missing URL"}'::jsonb WHERE uri=$1`, uri(1))
	assertKey(uri(1), uri(1))
	// An unchanged source update must not rewrite the derived row.
	if err := db.QueryRow(`SELECT xmin::text FROM content_item_article_identities WHERE uri=$1`, uri(1)).Scan(&before); err != nil {
		t.Fatal(err)
	}
	execute(`UPDATE content_items SET render_json=render_json WHERE uri=$1`, uri(1))
	if err := db.QueryRow(`SELECT xmin::text FROM content_item_article_identities WHERE uri=$1`, uri(1)).Scan(&after); err != nil || before != after {
		t.Fatalf("unchanged key caused a derived rewrite: %s %s %v", before, after, err)
	}
	// The query retains exact fallback semantics while a projection is missing.
	execute(`DELETE FROM content_item_article_identities WHERE uri=$1`, uri(1))
	metadata, _ := json.Marshal([]map[string]any{{"id": 0, "uri": uri(1), "at": time.Now().UTC(), "publication": "pub", "author": "did:plc:identity", "site": ""}})
	var id int64
	var key string
	var read bool
	if err := db.QueryRow(feedHydrateQuery, string(metadata), "did:plc:identity-viewer").Scan(&id, &key, &read); err != nil || key != uri(1) {
		t.Fatalf("missing identity fallback: key=%s error=%v", key, err)
	}
	if output, err := runSQL(migration[backfillStart:], schema+"_repair"); err != nil {
		t.Fatalf("missing identity repair: %v %s", err, output)
	}
	assertKey(uri(1), uri(1))
	waitForLock := func(application string, finished <-chan error) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			select {
			case err := <-finished:
				t.Fatalf("backfill completed before controlled lock race: %v", err)
			default:
			}
			var blocked bool
			if err := admin.QueryRow(`SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name=$1 AND wait_event_type='Lock')`, application).Scan(&blocked); err != nil {
				t.Fatal(err)
			}
			if blocked {
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
		t.Fatal("backfill did not reach the controlled row-lock boundary")
	}
	for _, deleting := range []bool{false, true} {
		subject := uri(2)
		if deleting {
			subject = uri(3)
		}
		execute(`DELETE FROM content_item_article_identities WHERE uri=$1`, subject)
		tx, err := db.Begin()
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback()
		if deleting {
			_, err = tx.Exec(`DELETE FROM content_items WHERE uri=$1`, subject)
		} else {
			_, err = tx.Exec(`UPDATE content_items SET render_json='{"title":"Updated","articleUrl":"https://fixture.invalid/newest"}'::jsonb WHERE uri=$1`, subject)
		}
		if err != nil {
			t.Fatal(err)
		}
		application := fmt.Sprintf("%s_race_%t", schema, deleting)
		finished := make(chan error, 1)
		go func() {
			output, err := runSQL(migration[backfillStart:], application)
			if err != nil {
				err = fmt.Errorf("%w: %s", err, output)
			}
			finished <- err
		}()
		waitForLock(application, finished)
		if err := tx.Commit(); err != nil {
			t.Fatal(err)
		}
		if err := <-finished; err != nil {
			t.Fatal(err)
		}
		if deleting {
			if err := db.QueryRow(`SELECT COUNT(*) FROM content_item_article_identities WHERE uri=$1`, subject).Scan(&count); err != nil || count != 0 {
				t.Fatalf("deleted source retained an identity: count=%d error=%v", count, err)
			}
		} else {
			assertKey(subject, "https://fixture.invalid/newest")
		}
	}
	// Ordinary source deletion also cascades an existing projection.
	execute(`DELETE FROM content_items WHERE uri=$1`, uri(4))
	if err := db.QueryRow(`SELECT COUNT(*) FROM content_item_article_identities WHERE uri=$1`, uri(4)).Scan(&count); err != nil || count != 0 {
		t.Fatalf("cascade cleanup failed: count=%d error=%v", count, err)
	}
}
