package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"net/http"
	"strings"
	"sync"
	"time"
)

type Repository interface {
	GetRecord(context.Context, string, string, string, string) (*gatewaycore.RepoRecord, error)
	ListRecords(context.Context, string, string, string, int, bool) (gatewaycore.RepoPage, error)
	Mutate(context.Context, gatewaycore.AuthContext, string, map[string]any) (map[string]json.RawMessage, error)
}
type Preferences struct {
	Repo    Repository
	Cache   *RecordCache
	Context context.Context
	mu      sync.Mutex
	active  map[string]bool
	wg      sync.WaitGroup
}

func (p *Preferences) Wait() { p.wg.Wait() }
func (p *Preferences) Register(mux *http.ServeMux, auth func(http.Handler) http.Handler) {
	for _, path := range []string{"/v1/sync/preferences", "/xrpc/app.thesocialwire.sync.getPreferences"} {
		mux.Handle("GET "+path, auth(http.HandlerFunc(p.preferences)))
	}
	mux.Handle("GET /v1/pds/cache/record", auth(http.HandlerFunc(p.generic)))
	mux.Handle("POST /v1/sync/migrate-lexicons", auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a, _ := gatewaycore.AuthContextFrom(r.Context())
		summary, e := p.Migrate(r.Context(), a)
		if e != nil {
			p.fail(w, e)
			return
		}
		writeJSON(w, 200, map[string]any{"summary": summary})
	})))
}
func (p *Preferences) preferences(w http.ResponseWriter, r *http.Request) {
	a, _ := gatewaycore.AuthContextFrom(r.Context())
	force := r.URL.Query().Get("fresh") == "true" || r.URL.Query().Get("fresh") == "1"
	if !force {
		if _, e := p.Migrate(r.Context(), a); e != nil {
			p.fail(w, e)
			return
		}
	}
	p.serve(w, r, a, "app.thesocialwire.preferences", "self", true, force)
}
func (p *Preferences) generic(w http.ResponseWriter, r *http.Request) {
	a, _ := gatewaycore.AuthContextFrom(r.Context())
	collection, key := r.URL.Query().Get("collection"), r.URL.Query().Get("rkey")
	if strings.TrimSpace(collection) == "" || strings.TrimSpace(key) == "" {
		writeError(w, 400, "Query requires collection and rkey")
		return
	}
	p.serve(w, r, a, collection, key, false, false)
}
func (p *Preferences) serve(w http.ResponseWriter, r *http.Request, a gatewaycore.AuthContext, collection, key string, prefs, force bool) {
	scope := collection + ":" + key
	if !force {
		warm, e := p.Cache.Get(r.Context(), a.DID, scope)
		if e != nil {
			p.fail(w, e)
			return
		}
		if warm != nil {
			fresh := 2 * time.Minute
			if prefs {
				fresh = 5 * time.Minute
			}
			if time.Since(time.UnixMilli(int64(warm.CachedAt))) >= fresh {
				p.schedule(a, collection, key)
			}
			p.respond(w, r, warm, prefs)
			return
		}
	}
	var lease *thinappviewcore.RefreshLease
	if !force {
		lease, _ = p.Cache.Acquire(r.Context(), a.DID, scope)
		if lease == nil {
			timer := time.NewTimer(250 * time.Millisecond)
			select {
			case <-r.Context().Done():
				timer.Stop()
				return
			case <-timer.C:
			}
			if warm, e := p.Cache.Get(r.Context(), a.DID, scope); e == nil && warm != nil {
				p.respond(w, r, warm, prefs)
				return
			}
		}
	}
	v, e := p.fetchWithLease(r.Context(), a, collection, key, lease)
	if e != nil {
		p.fail(w, e)
		return
	}
	if v == nil {
		if prefs {
			writeJSON(w, 200, map[string]any{"etag": nil, "cid": nil, "revision": nil, "cachedAt": time.Now().UTC().Format(time.RFC3339Nano), "record": nil})
		} else {
			writeError(w, 500, "PDS record not found")
		}
		return
	}
	p.respond(w, r, v, prefs)
}
func (p *Preferences) fetchWithLease(ctx context.Context, a gatewaycore.AuthContext, collection, key string, lease *thinappviewcore.RefreshLease) (*RecordSnapshot, error) {
	work, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan struct{})
	if lease != nil {
		go func() {
			defer close(done)
			ticker := time.NewTicker(5 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-work.Done():
					return
				case <-ticker.C:
					if !p.Cache.Renew(work, *lease) {
						cancel()
						return
					}
				}
			}
		}()
		defer func() {
			cancel()
			<-done
			release, stop := context.WithTimeout(context.WithoutCancel(ctx), time.Second)
			defer stop()
			p.Cache.Release(release, *lease)
		}()
	}
	record, e := p.Repo.GetRecord(work, a.DID, collection, key, "")
	if e != nil || record == nil {
		return nil, e
	}
	raw, e := json.Marshal(record)
	if len(record.RawJSON) > 0 {
		raw = record.RawJSON
	}
	if e != nil {
		return nil, e
	}
	v := &RecordSnapshot{JSONBody: string(raw), CachedAt: float64(time.Now().UnixMilli())}
	if record.CID != "" {
		v.CID = &record.CID
	}
	if e = p.Cache.Put(work, a.DID, collection+":"+key, *v); e != nil {
		return nil, e
	}
	return v, nil
}
func (p *Preferences) schedule(a gatewaycore.AuthContext, collection, key string) {
	ctx := p.Context
	if ctx == nil {
		ctx = context.Background()
	}
	id := a.DID + ":" + collection + ":" + key
	p.mu.Lock()
	if p.active == nil {
		p.active = map[string]bool{}
	}
	if p.active[id] || len(p.active) >= 64 || ctx.Err() != nil {
		p.mu.Unlock()
		return
	}
	p.active[id] = true
	p.wg.Add(1)
	p.mu.Unlock()
	go func() {
		defer p.wg.Done()
		defer func() { p.mu.Lock(); delete(p.active, id); p.mu.Unlock() }()
		lease, _ := p.Cache.Acquire(ctx, a.DID, collection+":"+key)
		if lease == nil {
			return
		}
		_, _ = p.fetchWithLease(ctx, a, collection, key, lease)
	}()
}
func (p *Preferences) respond(w http.ResponseWriter, r *http.Request, v *RecordSnapshot, prefs bool) {
	if v.CID != nil {
		etag := `"` + *v.CID + `"`
		w.Header().Set("ETag", etag)
		if strings.Trim(strings.TrimSpace(r.Header.Get("If-None-Match")), `"`) == *v.CID {
			w.WriteHeader(304)
			return
		}
	}
	if !prefs {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(200)
		w.Write([]byte(v.JSONBody))
		return
	}
	record, e := snapshotRecord(v)
	if e != nil {
		p.fail(w, e)
		return
	}
	writeJSON(w, 200, map[string]any{"etag": v.CID, "cid": v.CID, "revision": v.CID, "cachedAt": time.UnixMilli(int64(v.CachedAt)).UTC().Format(time.RFC3339Nano), "record": record})
}
func (p *Preferences) fail(w http.ResponseWriter, e error) {
	var upstream gatewaycore.PDSHTTPError
	if errors.As(e, &upstream) {
		if upstream.Nonce != "" {
			w.Header().Set("DPoP-Nonce", upstream.Nonce)
		}
		writeError(w, upstream.Status, upstream.Message)
		return
	}
	if errors.Is(e, gatewaycore.ErrAuthentication) {
		writeError(w, 401, "PDS authentication failed")
		return
	}
	writeError(w, 502, "PDS dependency unavailable")
}
