package topicreadcore

import (
	"context"
	"database/sql"
	"errors"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"os"
	"strings"
	"testing"
	"time"
)

type selectionRepo struct {
	pages []gatewaycore.RepoPage
	err   error
	calls int
}

func (r *selectionRepo) ListRecords(context.Context, string, string, string, int, bool) (gatewaycore.RepoPage, error) {
	r.calls++
	if r.err != nil {
		return gatewaycore.RepoPage{}, r.err
	}
	if r.calls > len(r.pages) {
		return gatewaycore.RepoPage{}, errors.New("unexpected page")
	}
	return r.pages[r.calls-1], nil
}
func selectionDB(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_CORPUS_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires disposable PostgreSQL")
	}
	c, e := pgx.ParseConfig(dsn)
	if e != nil {
		t.Fatal(e)
	}
	if c.Host != "127.0.0.1" || !strings.Contains(c.Database, "test") {
		t.Fatal("disposable loopback required")
	}
	db := stdlib.OpenDB(*c)
	t.Cleanup(func() { db.Close() })
	return db
}
func TestSelectionRefreshFencesNewerWorkerEvents(t *testing.T) {
	for _, domain := range []string{"finance", "sports"} {
		t.Run(domain, func(t *testing.T) {
			db := selectionDB(t)
			now := time.Now().UTC()
			viewer := "did:example:topic-" + domain
			t.Cleanup(func() {
				for _, suffix := range []string{"_selections", "_selection_versions", "_selection_sync"} {
					db.Exec(`DELETE FROM `+domain+suffix+` WHERE viewer_did=$1`, viewer)
				}
			})
			kind := "kind"
			action := "instrument"
			keyFor := func(ref string) string { return financecore.SelectionRecordKey("instrument", ref) }
			if domain == "sports" {
				kind = "action"
				action = "follow"
				keyFor = sportscore.SelectionRecordKey
			}
			p := &SelectionProjection{DB: db}
			for _, ref := range []string{"old", "newer", "deleted"} {
				at := now.Add(-time.Minute)
				if ref != "old" {
					at = now.Add(time.Minute)
				}
				if _, e := db.Exec(`INSERT INTO `+domain+`_selection_versions(viewer_did,record_key,event_at,repo_rev,is_deleted)VALUES($1,$2,$3,'worker',$4)`, viewer, keyFor(ref), at, ref == "deleted"); e != nil {
					t.Fatal(e)
				}
				if ref != "deleted" {
					if _, e := db.Exec(`INSERT INTO `+domain+`_selections(viewer_did,record_key,`+kind+`,reference,updated_at)VALUES($1,$2,$3,$4,$5)`, viewer, keyFor(ref), action, ref, at); e != nil {
						t.Fatal(e)
					}
				}
			}
			if e := p.apply(context.Background(), domain, viewer, []selectionRow{{keyFor("deleted"), action, "deleted"}, {keyFor("fresh"), action, "fresh"}}, now); e != nil {
				t.Fatal(e)
			}
			rows, e := p.selections(context.Background(), domain, viewer, false, now)
			if e != nil {
				t.Fatal(e)
			}
			refs := map[string]bool{}
			for _, r := range rows {
				refs[r.reference] = true
			}
			if len(refs) != 2 || !refs["newer"] || !refs["fresh"] {
				t.Fatal(refs)
			}
			var deleted bool
			if e = db.QueryRow(`SELECT is_deleted FROM `+domain+`_selection_versions WHERE viewer_did=$1 AND record_key=$2`, viewer, keyFor("old")).Scan(&deleted); e != nil || !deleted {
				t.Fatal(deleted, e)
			}
			p.Repo = &selectionRepo{err: errors.New("offline")}
			if _, e = p.selections(context.Background(), domain, viewer, true, now); !errors.Is(e, ErrUnavailable) {
				t.Fatal(e)
			}
		})
	}
}
func TestSelectionCyclicPaginationCannotReplace(t *testing.T) {
	db := selectionDB(t)
	viewer := "did:example:topic-cycle"
	p := &SelectionProjection{DB: db, Repo: &selectionRepo{pages: []gatewaycore.RepoPage{{Cursor: "a"}, {Cursor: "b"}, {Cursor: "a"}}}}
	if e := p.refresh(context.Background(), "finance", viewer, time.Now()); !errors.Is(e, ErrUnavailable) {
		t.Fatal(e)
	}
	var count int
	if e := db.QueryRow(`SELECT count(*) FROM finance_selection_sync WHERE viewer_did=$1`, viewer).Scan(&count); e != nil || count != 0 {
		t.Fatal(count, e)
	}
}
