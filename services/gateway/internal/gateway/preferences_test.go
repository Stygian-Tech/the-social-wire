package gateway

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeRepository struct {
	mu      sync.Mutex
	records map[string]*gatewaycore.RepoRecord
	calls   int
	failPut bool
	writes  []string
}

func (f *fakeRepository) GetRecord(_ context.Context, _, c, k, _ string) (*gatewaycore.RepoRecord, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	return f.records[c+":"+k], nil
}
func (f *fakeRepository) ListRecords(_ context.Context, _, c, cursor string, limit int, _ bool) (gatewaycore.RepoPage, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	rows := []gatewaycore.RepoRecord{}
	for key, r := range f.records {
		if strings.HasPrefix(key, c+":") {
			rows = append(rows, *r)
			if len(rows) == limit {
				break
			}
		}
	}
	return gatewaycore.RepoPage{Records: rows}, nil
}
func (f *fakeRepository) Mutate(_ context.Context, _ gatewaycore.AuthContext, m string, body map[string]any) (map[string]json.RawMessage, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.failPut && strings.HasSuffix(m, "putRecord") {
		return nil, fmt.Errorf("write failed")
	}
	f.writes = append(f.writes, m)
	if strings.HasSuffix(m, "deleteRecord") {
		delete(f.records, body["collection"].(string)+":"+body["rkey"].(string))
	}
	return nil, nil
}
func newPreferencesFixture(t *testing.T) (*Preferences, *fakeRepository) {
	t.Helper()
	m := miniredis.RunT(t)
	r := redis.NewClient(&redis.Options{Addr: m.Addr()})
	t.Cleanup(func() { r.Close() })
	repo := &fakeRepository{records: map[string]*gatewaycore.RepoRecord{}}
	return &Preferences{Repo: repo, Cache: &RecordCache{Backend: "redis", Redis: r, Namespace: socialwireredis.NewKeyNamespace("dev", "")}}, repo
}
func TestPreferencesETagAndViewerCacheIsolation(t *testing.T) {
	p, f := newPreferencesFixture(t)
	f.records["app.thesocialwire.preferences:self"] = &gatewaycore.RepoRecord{URI: "at://did:plc:a/app.thesocialwire.preferences/self", CID: "cid", Value: map[string]json.RawMessage{"theme": json.RawMessage(`"dark"`)}}
	r := httptest.NewRequest("GET", "https://gateway.invalid/v1/sync/preferences?fresh=true", nil)
	r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:a"}))
	w := httptest.NewRecorder()
	p.preferences(w, r)
	if w.Code != 200 || w.Header().Get("ETag") != `"cid"` {
		t.Fatal(w.Body.String())
	}
	var b map[string]any
	if json.Unmarshal(w.Body.Bytes(), &b) != nil || b["record"].(map[string]any)["theme"] != "dark" {
		t.Fatal(b)
	}
	r = httptest.NewRequest("GET", "https://gateway.invalid/v1/sync/preferences", nil)
	r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:a"}))
	r.Header.Set("If-None-Match", `"cid"`)
	w = httptest.NewRecorder()
	p.preferences(w, r)
	if w.Code != 304 {
		t.Fatal(w.Code)
	}
	if v, e := p.Cache.Get(context.Background(), "did:plc:b", "app.thesocialwire.preferences:self"); e != nil || v != nil {
		t.Fatal("cross viewer cache")
	}
}
func TestStaleRecordReturnsBeforeLeasedRefresh(t *testing.T) {
	p, f := newPreferencesFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	p.Context = ctx
	defer cancel()
	v := RecordSnapshot{JSONBody: `{"uri":"at://did:plc:a/c/k","cid":"old","value":{"name":"old"}}`, CachedAt: float64(time.Now().Add(-3 * time.Minute).UnixMilli())}
	cid := "old"
	v.CID = &cid
	p.Cache.Put(ctx, "did:plc:a", "c:k", v)
	f.records["c:k"] = &gatewaycore.RepoRecord{CID: "new", Value: map[string]json.RawMessage{"name": json.RawMessage(`"new"`)}}
	r := httptest.NewRequest("GET", "https://gateway.invalid/v1/pds/cache/record?collection=c&rkey=k", nil)
	r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:a"}))
	w := httptest.NewRecorder()
	p.generic(w, r)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "old") {
		t.Fatal(w.Body.String())
	}
	p.Wait()
	warm, _ := p.Cache.Get(ctx, "did:plc:a", "c:k")
	if warm == nil || warm.CID == nil || *warm.CID != "new" {
		t.Fatal("refresh failed")
	}
}
func TestMigrationFailedCopyNeverDeletesSource(t *testing.T) {
	p, f := newPreferencesFixture(t)
	f.failPut = true
	f.records["com.thesocialwire.folder:k"] = &gatewaycore.RepoRecord{URI: "at://did:plc:a/com.thesocialwire.folder/k", Value: map[string]json.RawMessage{"name": json.RawMessage(`"Folder"`)}}
	_, e := p.Migrate(context.Background(), gatewaycore.AuthContext{DID: "did:plc:a"})
	if e == nil || len(f.writes) != 0 || f.records["com.thesocialwire.folder:k"] == nil {
		t.Fatal("failed migration lost source")
	}
}
func TestMissingPreferencesNotCached(t *testing.T) {
	p, f := newPreferencesFixture(t)
	for range 2 {
		r := httptest.NewRequest("GET", "https://gateway.invalid/v1/sync/preferences?fresh=true", nil)
		r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:a"}))
		w := httptest.NewRecorder()
		p.preferences(w, r)
		if w.Code != 200 || !strings.Contains(w.Body.String(), `"record":null`) {
			t.Fatal(w.Body.String())
		}
	}
	if f.calls != 2 {
		t.Fatal("absence was cached")
	}
}
