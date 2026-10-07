package publicationcore

import (
	"context"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewworkercore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

type getterFunc func(context.Context, string, http.Header, int, int) (int, http.Header, []byte, error)

func (f getterFunc) Get(ctx context.Context, url string, h http.Header, max, redirects int) (int, http.Header, []byte, error) {
	return f(ctx, url, h, max, redirects)
}
func TestEnrollUsesPublicBoundedForwardPaginationAndFullFailure(t *testing.T) {
	db := fixtureDB(t)
	did := fmt.Sprintf("did:web:enroll%d.publisher.social", time.Now().UnixNano())
	ctx := context.Background()
	at := time.Now().UTC()
	t.Cleanup(func() { db.Exec(`DELETE FROM content_items WHERE author_did=$1`, did) })
	var mu sync.Mutex
	requests := []url.Values{}
	getter := getterFunc(func(ctx context.Context, target string, h http.Header, max, redirects int) (int, http.Header, []byte, error) {
		if h.Get("Authorization") != "" || h.Get("DPoP") != "" || redirects != 0 {
			t.Error("public PDS auth or redirect leak")
		}
		if strings.Contains(target, "/.well-known/did.json") {
			return 200, nil, []byte(fmt.Sprintf(`{"id":%q,"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.publisher.social"}]}`, did)), nil
		}
		u, _ := url.Parse(target)
		q := u.Query()
		mu.Lock()
		requests = append(requests, q)
		mu.Unlock()
		if q.Get("collection") == "site.standard.entry" {
			return 200, nil, []byte(`{"records":[]}`), nil
		}
		if q.Get("reverse") == "true" {
			return 400, nil, []byte(`{"error":"InvalidRequest","message":"reverse pagination not supported"}`), nil
		}
		key := "a"
		cursor := `,"cursor":"next"`
		if q.Get("cursor") == "next" {
			key = "b"
			cursor = ""
		}
		body := fmt.Sprintf(`{"records":[{"uri":%q,"cid":"fixture","value":{"$type":"site.standard.document","title":"Fixture","publishedAt":%q,"textContent":"Content"}}]%s}`, "at://"+did+"/site.standard.document/"+key, at.Format(time.RFC3339), cursor)
		return 200, nil, []byte(body), nil
	})
	pds := &thinappviewcore.PDSClient{HTTP: getter, PLCBase: "https://plc.fixture"}
	enroll := Enroller{DB: db, PDS: pds, HTTP: getter, Projection: &appviewworkercore.EventProjectorRuntime{DB: db, PDS: pds, Counters: thinappviewcore.CounterStore{DB: db}}, MaximumRecords: 5, Concurrency: 1}
	n, err := enroll.Enroll(ctx, gatewaycore.AuthContext{DID: did}, []string{did}, nil, false)
	if err != nil || n != 2 {
		t.Fatalf("full indexed %d %v", n, err)
	}
	for _, q := range requests {
		if q.Get("collection") == "site.standard.document" && q.Get("limit") != "1" {
			t.Fatal("exceeded hosted document cap")
		}
	}
	enroll.MaximumRecords = 1
	n, err = enroll.Enroll(ctx, gatewaycore.AuthContext{DID: did}, []string{did}, nil, false)
	if err == nil || n != 1 {
		t.Fatalf("full cap concealed incomplete count=%d err=%v", n, err)
	}
	enroll.MaximumRecords = 5
	n, err = enroll.Enroll(ctx, gatewaycore.AuthContext{DID: did}, []string{did}, nil, true)
	if err != nil || n != 1 {
		t.Fatalf("recent pagination blocked/expanded %d %v", n, err)
	}
}
func TestRetryDelayPolicy(t *testing.T) {
	at := time.Now()
	for _, tt := range []struct {
		raw     string
		attempt int
		want    time.Duration
	}{{"2", 1, 2400 * time.Millisecond}, {"900", 1, 30 * time.Second}, {"nonsense", 3, 4800 * time.Millisecond}, {at.Add(-time.Minute).UTC().Format(http.TimeFormat), 1, 0}} {
		if got := retryDelay(tt.raw, tt.attempt, at, .2); got != tt.want {
			t.Fatalf("delay %q %v want %v", tt.raw, got, tt.want)
		}
	}
}
