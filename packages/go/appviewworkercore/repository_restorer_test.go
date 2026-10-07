package appviewworkercore

import (
	"context"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestRepositoryRetryAfterBounds(t *testing.T) {
	at := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	for _, test := range []struct {
		value   string
		attempt int
		want    time.Duration
	}{{"0.5", 1, 500 * time.Millisecond}, {"3600", 1, time.Minute}, {"Tue, 06 Oct 2026 12:00:05 GMT", 1, 5 * time.Second}, {"Tue, 06 Oct 2026 11:00:05 GMT", 1, 0}, {"invalid", 2, 2 * time.Second}} {
		if got := repositoryRetryDelay(test.value, test.attempt, at); got != test.want {
			t.Fatalf("%s got %s want %s", test.value, got, test.want)
		}
	}
}

type restorationHTTP struct {
	did       string
	failEntry bool
	documents int
}

func (g *restorationHTTP) Get(_ context.Context, raw string, _ http.Header, _ int, _ int) (int, http.Header, []byte, error) {
	u, _ := url.Parse(raw)
	if strings.HasSuffix(u.Path, "/did.json") {
		return 200, nil, []byte(fmt.Sprintf(`{"id":%q,"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.publisher.social"}]}`, g.did)), nil
	}
	if u.Query().Get("collection") == "site.standard.entry" {
		if g.failEntry {
			return 503, nil, nil, nil
		}
		return 200, nil, []byte(`{"records":[]}`), nil
	}
	g.documents++
	return 200, nil, []byte(fmt.Sprintf(`{"records":[{"uri":%q,"cid":"fixture-cid","value":{"title":"Snapshot","publishedAt":"2026-10-06T12:00:00Z"}}]}`, "at://"+g.did+"/site.standard.document/seen")), nil
}
func TestRestorerDoesNotPruneUntilEveryCollectionComplete(t *testing.T) {
	db := workerDatabase(t)
	nonce, err := newSnapshotToken()
	if err != nil {
		t.Fatal(err)
	}
	did := "did:web:publisher.social:" + nonce
	env := "restore-" + nonce
	at := time.Now().UTC()
	scope := thinappviewcore.RecoveryContext{Environment: env, SourceGeneration: "fixture", Sequence: 1, RepoDID: did, WorkerID: "worker", LeaseToken: "token"}
	t.Cleanup(func() {
		db.Exec("DELETE FROM appview_repository_recovery_records WHERE environment=$1", env)
		db.Exec("DELETE FROM appview_ingestion_inbox WHERE environment=$1", env)
		db.Exec("DELETE FROM content_items WHERE author_did=$1", did)
	})
	if _, err := db.Exec(`INSERT INTO appview_ingestion_inbox(environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,payload,event_time,status,lease_owner,lease_token,lease_expires_at)VALUES($1,'fixture',1,'fixture','jetstream_v2_seq','sync',$2,'{}',$3,'leased','worker','token',$4)`, env, did, at, at.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	content := thinappviewcore.ContentStore{DB: db}
	missing := "at://" + did + "/site.standard.document/missing"
	if err := content.Upsert(context.Background(), thinappviewcore.IndexedContentItem{URI: missing, CID: "old", AuthorDID: did, Collection: "site.standard.document", CreatedAt: at.Add(-time.Hour), IndexedAt: at.Add(-time.Hour), ExpiresAt: at.Add(time.Hour), Render: thinappviewcore.ContentRenderFields{Title: "Missing", PublishedAt: at.Add(-time.Hour).Format(time.RFC3339)}}); err != nil {
		t.Fatal(err)
	}
	getter := &restorationHTTP{did: did, failEntry: true}
	pds := &thinappviewcore.PDSClient{HTTP: getter}
	projector := &EventProjectorRuntime{DB: db, PDS: pds, Counters: thinappviewcore.CounterStore{DB: db}}
	r := RepositoryRestorer{DB: db, PDS: pds, Projector: projector, RecordBudget: 100}
	if err := r.Restore(context.Background(), scope); err == nil {
		t.Fatal("failed collection accepted")
	}
	if exists, err := content.Exists(context.Background(), missing); err != nil || !exists {
		t.Fatalf("premature pruning %v %v", exists, err)
	}
	getter.failEntry = false
	if err := r.Restore(context.Background(), scope); err != nil {
		t.Fatal(err)
	}
	if getter.documents != 1 {
		t.Fatal("complete document page was refetched")
	}
	if exists, err := content.Exists(context.Background(), missing); err != nil || exists {
		t.Fatalf("complete snapshot did not prune %v %v", exists, err)
	}
}
