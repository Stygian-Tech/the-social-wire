package gateway

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
)

func draftRedisAdmission(t *testing.T) (*miniredis.Miniredis, *socialDraftAdmission) {
	t.Helper()
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr(), MaxRetries: -1, ContextTimeoutEnabled: true})
	t.Cleanup(func() { client.Close() })
	return server, &socialDraftAdmission{redis: client, namespace: socialwireredis.NewKeyNamespace("dev", "")}
}

func TestSocialDraftAdmissionOwnerRateAndRefill(t *testing.T) {
	for _, shared := range []bool{false, true} {
		t.Run(fmt.Sprint(shared), func(t *testing.T) {
			a := &socialDraftAdmission{}
			now := time.Now()
			var server *miniredis.Miniredis
			if shared {
				server, a = draftRedisAdmission(t)
				server.SetTime(now)
			}
			otherReplica := a
			if shared {
				otherReplica = &socialDraftAdmission{redis: a.redis, namespace: a.namespace}
			}
			for i := 0; i < 120; i++ {
				replica := a
				if i%2 != 0 {
					replica = otherReplica
				}
				release, status := replica.acquire(context.Background(), "did:plc:owner", false, now)
				if status != 0 {
					t.Fatal(i, status)
				}
				release()
			}
			if _, status := a.acquire(context.Background(), "did:plc:owner", false, now); status != 429 {
				t.Fatal("owner budget bypassed", status)
			}
			release, status := a.acquire(context.Background(), "did:plc:other", false, now)
			if status != 0 {
				t.Fatal("owners share request budget", status)
			}
			release()
			now = now.Add(time.Second)
			if shared {
				server.SetTime(now)
			}
			for i := 0; i < 10; i++ {
				release, status = a.acquire(context.Background(), "did:plc:owner", false, now)
				if status != 0 {
					t.Fatal("request tokens did not refill at ten per second", i, status)
				}
				release()
			}
			if _, status := a.acquire(context.Background(), "did:plc:owner", false, now); status != 429 {
				t.Fatal("request refill exceeds ten per second", status)
			}
		})
	}
}

func TestSocialDraftAdmissionUploadRateIsSeparate(t *testing.T) {
	for _, shared := range []bool{false, true} {
		t.Run(fmt.Sprint(shared), func(t *testing.T) {
			a := &socialDraftAdmission{}
			now := time.Now()
			var server *miniredis.Miniredis
			if shared {
				server, a = draftRedisAdmission(t)
				server.SetTime(now)
			}
			for i := 0; i < 32; i++ {
				release, status := a.acquire(context.Background(), "did:plc:owner", true, now)
				if status != 0 {
					t.Fatal(i, status)
				}
				release()
			}
			if _, status := a.acquire(context.Background(), "did:plc:owner", true, now); status != 429 {
				t.Fatal("upload budget bypassed", status)
			}
			release, status := a.acquire(context.Background(), "did:plc:owner", false, now)
			if status != 0 {
				t.Fatal("upload limit blocks manifest access", status)
			}
			release()
			now = now.Add(time.Second)
			if shared {
				server.SetTime(now)
			}
			release, status = a.acquire(context.Background(), "did:plc:owner", true, now)
			if status != 0 {
				t.Fatal("upload token did not refill at one per second", status)
			}
			release()
			if _, status := a.acquire(context.Background(), "did:plc:owner", true, now); status != 429 {
				t.Fatal("upload refill exceeds one per second", status)
			}
		})
	}
}

func TestSocialDraftUploadSlotsAreSharedAcrossReplicas(t *testing.T) {
	_, a := draftRedisAdmission(t)
	b := &socialDraftAdmission{redis: a.redis, namespace: a.namespace}
	var releases []func()
	defer func() {
		for _, release := range releases {
			release()
		}
	}()
	for i := 0; i < socialDraftUploadSlots; i++ {
		replica := a
		if i%2 != 0 {
			replica = b
		}
		release, status := replica.acquire(context.Background(), fmt.Sprintf("did:plc:owner%d", i/2), true, time.Now())
		if status != 0 {
			t.Fatal(i, status)
		}
		releases = append(releases, release)
	}
	if _, status := b.acquire(context.Background(), "did:plc:overflow", true, time.Now()); status != 429 {
		t.Fatal("replicas multiplied global slots", status)
	}
	releases[0]()
	releases = releases[1:]
	if _, status := a.acquire(context.Background(), "did:plc:owner1", true, time.Now()); status != 429 {
		t.Fatal("per-DID active limit bypassed", status)
	}
	release, status := b.acquire(context.Background(), "did:plc:overflow", true, time.Now())
	if status != 0 {
		t.Fatal("released global slot not reusable", status)
	}
	releases = append(releases, release)
}

func TestSocialDraftAdmissionConcurrentGlobalBound(t *testing.T) {
	for _, shared := range []bool{false, true} {
		t.Run(fmt.Sprint(shared), func(t *testing.T) {
			a := &socialDraftAdmission{}
			if shared {
				_, a = draftRedisAdmission(t)
			}
			finish := make(chan struct{})
			var attempts, workers sync.WaitGroup
			statuses := make(chan int, 32)
			for i := 0; i < 32; i++ {
				attempts.Add(1)
				workers.Add(1)
				go func(i int) {
					defer workers.Done()
					release, status := a.acquire(context.Background(), fmt.Sprintf("did:plc:%d", i), true, time.Now())
					statuses <- status
					attempts.Done()
					if status == 0 {
						<-finish
						release()
					}
				}(i)
			}
			attempts.Wait()
			close(statuses)
			accepted := 0
			for status := range statuses {
				if status == 0 {
					accepted++
				} else if status != 429 {
					t.Error("unexpected status", status)
				}
			}
			close(finish)
			workers.Wait()
			if accepted != socialDraftUploadSlots {
				t.Fatal("wrong upload concurrency", accepted)
			}
		})
	}
}

func TestSocialDraftRedisOutageFailsClosedWithoutLocalLeak(t *testing.T) {
	server, a := draftRedisAdmission(t)
	server.Close()
	if release, status := a.acquire(context.Background(), "did:plc:owner", true, time.Now()); status != 503 || release != nil {
		t.Fatal("Redis failure admitted upload", status)
	}
	if a.active != 0 || a.owners["did:plc:owner"].active != 0 {
		t.Fatal("local slots leaked")
	}
}

func TestSocialDraftLeaseExpiresAfterReplicaCrash(t *testing.T) {
	server, a := draftRedisAdmission(t)
	now := time.Now()
	server.SetTime(now)
	for i := 0; i < socialDraftUploadSlots; i++ {
		if _, status := a.acquire(context.Background(), fmt.Sprintf("did:plc:%d", i), true, now); status != 0 {
			t.Fatal(status)
		}
	}
	// Simulate process loss: no release function runs, but a new replica can recover.
	now = now.Add(socialDraftUploadTimeout + 6*time.Second)
	server.SetTime(now)
	server.FastForward(socialDraftUploadTimeout + 6*time.Second)
	b := &socialDraftAdmission{redis: a.redis, namespace: a.namespace}
	release, status := b.acquire(context.Background(), "did:plc:recovered", true, now)
	if status != 0 {
		t.Fatal("crashed replica retained slots", status)
	}
	release()
}

func TestSocialDraftMiddlewareRejectsBeforeUpstreamAndReleasesOnCancellation(t *testing.T) {
	_, a := draftRedisAdmission(t)
	calls := 0
	ctx, cancel := context.WithCancel(context.Background())
	handler := a.middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls++; cancel(); w.WriteHeader(204) }))
	r := httptest.NewRequest("POST", draftPrefix+"uploadAttachment", nil)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 401 || calls != 0 {
		t.Fatal("unauthenticated admission")
	}
	r = r.WithContext(gatewaycore.ContextWithAuth(ctx, gatewaycore.AuthContext{DID: "did:plc:owner"}))
	w = httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 204 || a.active != 0 {
		t.Fatal("cancellation leaked a local slot")
	}
	key := a.namespace.Key("social-draft-admission", []string{"active-uploads"}, nil)
	if count, err := a.redis.ZCard(context.Background(), key).Result(); err != nil || count != 0 {
		t.Fatal("cancellation leaked shared slot", count, err)
	}
	// Exhaust the request bucket; rejected requests never reach the next handler.
	now := time.Now()
	for i := 0; i < 120; i++ {
		release, status := a.acquire(context.Background(), "did:plc:limited", false, now)
		if status != 0 {
			t.Fatal(status)
		}
		release()
	}
	r = httptest.NewRequest("POST", draftPrefix+"reserveAttachment", nil)
	r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:limited"}))
	w = httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 429 || calls != 1 || w.Header().Get("Retry-After") == "" || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatal(w.Code, w.Header(), calls)
	}
}

type draftDeadlineWriter struct {
	*httptest.ResponseRecorder
	deadlines []time.Time
}

func (w *draftDeadlineWriter) SetReadDeadline(at time.Time) error {
	w.deadlines = append(w.deadlines, at)
	return nil
}
func TestSocialDraftUploadHasScopedReadAndUpstreamDeadline(t *testing.T) {
	now := time.Now()
	p := Proxy{Config: Config{AppViewURL: "https://appview.invalid"}, Internal: &http.Client{Transport: contractTransport(func(r *http.Request) (*http.Response, error) {
		deadline, ok := r.Context().Deadline()
		if !ok || time.Until(deadline) > socialDraftUploadTimeout || time.Until(deadline) < socialDraftUploadTimeout-time.Second {
			t.Error("upstream upload deadline missing")
		}
		return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(`{}`))}, nil
	})}}
	r := draftRequest("uploadAttachment", strings.NewReader("a"))
	r.Header.Set("Content-Type", "application/octet-stream")
	r.Header.Set("X-Social-Draft-Upload-Id", "asset")
	w := &draftDeadlineWriter{ResponseRecorder: httptest.NewRecorder()}
	p.Handler(draftRoute("uploadAttachment")).ServeHTTP(w, r)
	if w.Code != 200 || len(w.deadlines) != 2 || w.deadlines[0].Before(now.Add(socialDraftUploadTimeout)) || !w.deadlines[1].IsZero() {
		t.Fatal(w.Code, w.deadlines)
	}
}

func TestSocialDraftServerWiresAllSixRoutesIntoOneOwnerBudget(t *testing.T) {
	server, admission := draftRedisAdmission(t)
	server.SetTime(time.Now())
	upstreamCalls := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { upstreamCalls++; w.Write([]byte(`{}`)) }))
	defer upstream.Close()
	s := &Server{Config: Config{AppViewURL: upstream.URL}, HTTP: upstream.Client(), Limiter: &RequestLimiter{Redis: admission.redis, Namespace: admission.namespace}}
	handler := s.Handler() // Intentionally no DB: admission must never acquire SQL connections.
	var routes []Route
	for _, route := range Routes {
		if strings.HasPrefix(route.Path, draftPrefix) {
			routes = append(routes, route)
		}
	}
	for i := 0; i < 120; i++ {
		route := draftRoute("getManifest")
		if i < len(routes) {
			route = routes[i]
		}
		r := httptest.NewRequest(route.Method, route.Path, strings.NewReader("{}"))
		r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:owner"}))
		r.Header.Set("Content-Type", "application/octet-stream")
		r.Header.Set("X-Social-Draft-Upload-Id", "asset")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != 200 {
			t.Fatalf("%s: %d %s", route.Path, w.Code, w.Body.String())
		}
	}
	r := httptest.NewRequest("GET", draftPrefix+"getManifest", nil)
	r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:owner"}))
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 429 || upstreamCalls != 120 {
		t.Fatal("server bypassed draft admission", w.Code, upstreamCalls)
	}
}

type unreadDraftBody struct{ t *testing.T }

func (b unreadDraftBody) Read([]byte) (int, error) {
	b.t.Error("rejected upload body was read")
	return 0, io.EOF
}
func (b unreadDraftBody) Close() error { return nil }
func TestSocialDraftSaturatedUploadsRejectBeforeReadingOrForwarding(t *testing.T) {
	a := &socialDraftAdmission{}
	for i := 0; i < socialDraftUploadSlots; i++ {
		release, status := a.acquire(context.Background(), fmt.Sprintf("did:plc:%d", i), true, time.Now())
		if status != 0 {
			t.Fatal(status)
		}
		defer release()
	}
	next := http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Error("rejected upload reached upstream") })
	r := draftRequest("uploadAttachment", nil)
	r.Body = unreadDraftBody{t: t}
	r.ContentLength = 1
	w := httptest.NewRecorder()
	a.middleware(next).ServeHTTP(w, r)
	if w.Code != 429 || w.Header().Get("Connection") != "close" {
		t.Fatal(w.Code, w.Header())
	}
}

func TestSocialDraftFourPhotoBatchAdmittedThenUploadAbuseCapped(t *testing.T) {
	for _, shared := range []bool{false, true} {
		t.Run(fmt.Sprint(shared), func(t *testing.T) {
			a := &socialDraftAdmission{}
			if shared {
				server, replica := draftRedisAdmission(t)
				server.SetTime(time.Now())
				a = replica
			}
			calls := 0
			handler := a.middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls++; w.WriteHeader(204) }))
			call := func(name string) int {
				r := draftRequest(name, strings.NewReader("{}"))
				w := httptest.NewRecorder()
				handler.ServeHTTP(w, r)
				return w.Code
			}
			// Four photos each have original and prepared bytes: eight sequential
			// uploads, eight reserves, and eight manifest/autosave operations.
			for i := 0; i < 8; i++ {
				for _, name := range []string{"reserveAttachment", "uploadAttachment", "putManifest"} {
					if status := call(name); status != 204 {
						t.Fatalf("normal composer batch %d %s: %d", i, name, status)
					}
				}
			}
			if calls != 24 {
				t.Fatal("normal composer batch did not complete", calls)
			}
			for i := 8; i < 32; i++ {
				if status := call("uploadAttachment"); status != 204 {
					t.Fatal("advertised upload burst rejected", i, status)
				}
			}
			if status := call("uploadAttachment"); status != 429 {
				t.Fatal("upload abuse not capped", status)
			}
			if status := call("putManifest"); status != 204 {
				t.Fatal("upload cap turned autosave into an error", status)
			}
		})
	}
}
