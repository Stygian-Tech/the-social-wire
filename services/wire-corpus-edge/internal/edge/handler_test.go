package edge

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type fixtureStore struct {
	corpuscore.Store
	err       error
	feed      corpuscore.FeedQuery
	events    corpuscore.EventsQuery
	candidate corpuscore.CandidateRequest
}

func (s *fixtureStore) Ping(context.Context) error                            { return s.err }
func (s *fixtureStore) RequireFreshBaseline(context.Context, time.Time) error { return s.err }
func (s *fixtureStore) Feed(_ context.Context, q corpuscore.FeedQuery, now time.Time) (corpuscore.Page, error) {
	s.feed = q
	return corpuscore.Page{GenerationID: "test", GeneratedAt: now, Language: q.Language, Rows: []corpuscore.Row{}, Exhausted: true}, s.err
}
func (s *fixtureStore) Edition(context.Context, corpuscore.EditionQuery, time.Time) (corpuscore.Edition, error) {
	return corpuscore.Edition{Edition: wirecore.AssembleEdition("test", time.Unix(0, 0), "und", nil, "ranked", false, nil, nil)}, s.err
}
func (s *fixtureStore) Item(context.Context, string, time.Time) (*corpuscore.Item, error) {
	return nil, s.err
}
func (s *fixtureStore) Catalog(context.Context, time.Time) (corpuscore.Catalog, error) {
	return corpuscore.Catalog{SupportedLanguages: []string{}}, s.err
}
func (s *fixtureStore) CircleCandidates(_ context.Context, q corpuscore.CandidateRequest, now time.Time) (corpuscore.CandidateResponse, error) {
	s.candidate = q
	return corpuscore.CandidateResponse{GeneratedAt: now, Stories: []corpuscore.CandidateStory{}}, s.err
}
func (s *fixtureStore) Finance(context.Context, string, time.Time) (corpuscore.FinanceGeneration, error) {
	return corpuscore.FinanceGeneration{Candidates: []financecore.RankCandidate{}, Instruments: []financecore.Instrument{}}, s.err
}
func (s *fixtureStore) Sports(context.Context, string, time.Time) (corpuscore.SportsGeneration, error) {
	return corpuscore.SportsGeneration{Candidates: []sportscore.RankCandidate{}, Entities: []sportscore.Entity{}}, s.err
}
func (s *fixtureStore) SportsSchedules(context.Context, time.Time) ([]corpuscore.ScheduleStatus, error) {
	return []corpuscore.ScheduleStatus{}, s.err
}
func (s *fixtureStore) SportsStandings(context.Context, []string, time.Time) ([]sportscore.StandingSnapshot, error) {
	return []sportscore.StandingSnapshot{}, s.err
}
func (s *fixtureStore) SportsEvents(_ context.Context, q corpuscore.EventsQuery, _ time.Time) ([]sportscore.Event, error) {
	s.events = q
	return []sportscore.Event{}, s.err
}
func testHandler() (*Handler, *fixtureStore) {
	s := &fixtureStore{}
	h := NewHandler(s, Config{SharedSecret: strings.Repeat("s", 32), AllowedServiceID: "appview"})
	h.Now = func() time.Time { return time.Unix(1791324000, 0).UTC() }
	return h, s
}

var nonceCounter int

func signed(h *Handler, method, target string, body []byte) *http.Request {
	r := httptest.NewRequest(method, target, bytes.NewReader(body))
	var digest *string
	if body != nil {
		sum := sha256.Sum256(body)
		value := hex.EncodeToString(sum[:])
		digest = &value
	}
	nonceCounter++
	nonce := fmt.Sprintf("00000000-0000-4000-8000-%012d", nonceCounter)
	headers, err := wirecore.SignCorpusRequest([]byte(h.Config.SharedSecret), h.Config.AllowedServiceID, method, r.URL.RequestURI(), digest, h.Now(), nonce)
	if err != nil {
		panic(err)
	}
	r.Header.Set(wirecore.CorpusServiceHeader, headers.ServiceID)
	r.Header.Set(wirecore.CorpusTimestampHeader, headers.Timestamp)
	r.Header.Set(wirecore.CorpusNonceHeader, headers.Nonce)
	r.Header.Set(wirecore.CorpusSignatureHeader, headers.Signature)
	if headers.BodyDigest != nil {
		r.Header.Set(wirecore.CorpusBodyDigestHeader, *headers.BodyDigest)
	}
	return r
}
func perform(h *Handler, r *http.Request) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func TestCorpusAuthDenialsAndReplay(t *testing.T) {
	for _, header := range []string{"Authorization", "Cookie", "DPoP", "X-ATProto-Upstream-DPoP", "X-Wire-Moderation-DPoP", "X-SocialWire-Gateway-DID", "X-SocialWire-Gateway-Timestamp", "X-SocialWire-Gateway-Signature"} {
		t.Run(header, func(t *testing.T) {
			h, _ := testHandler()
			r := signed(h, "GET", "/internal/wire/v1/catalog", nil)
			r.Header.Set(header, "")
			if w := perform(h, r); w.Code != 401 {
				t.Fatalf("viewer header accepted: %d", w.Code)
			}
		})
	}
	h, _ := testHandler()
	r := signed(h, "GET", "/internal/wire/v1/catalog", nil)
	if perform(h, r).Code != 200 {
		t.Fatal("valid signature rejected")
	}
	if perform(h, r).Code != 401 {
		t.Fatal("replay accepted")
	}
	r = signed(h, "GET", "/internal/wire/v1/feed?language=en", nil)
	r.URL.RawQuery = "language=fr"
	if perform(h, r).Code != 401 {
		t.Fatal("target mutation accepted")
	}
	if perform(h, httptest.NewRequest("GET", "/internal/wire/v1/catalog", nil)).Code != 401 {
		t.Fatal("unsigned request accepted")
	}
	h.Replay = NewReplayGuard(1)
	if perform(h, signed(h, "GET", "/internal/wire/v1/catalog", nil)).Code != 200 || perform(h, signed(h, "GET", "/internal/wire/v1/catalog", nil)).Code != 401 {
		t.Fatal("capacity not fail closed")
	}
}
func TestAllServingRoutesAndQueryBounds(t *testing.T) {
	h, s := testHandler()
	for _, route := range []string{"contract", "finance", "sports", "sports/schedules", "sports/standings", "sports/events", "feed", "edition", "catalog"} {
		w := perform(h, signed(h, "GET", "/internal/wire/v1/"+route, nil))
		if w.Code != 200 || w.Header().Get("X-Wire-Corpus-Contract") != "3" || w.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("%s: %d %s", route, w.Code, w.Body.String())
		}
	}
	for _, target := range []string{"feed?limit=0", "feed?limit=501", "feed?limit=1&limit=2", "feed?%6cimit=1&limit=2", "feed?unknown=1", "feed?generationId=bad", "feed?startOrdinal=-1", "item?itemId=", "catalog?language=en", "sports/events?global=maybe", "sports/events?timeZone=Local", "sports/events?timeZone=No/Such"} {
		w := perform(h, signed(h, "GET", "/internal/wire/v1/"+target, nil))
		if w.Code != 400 {
			t.Fatalf("%s: %d", target, w.Code)
		}
	}
	if perform(h, signed(h, "GET", "/internal/wire/v1/item?itemId=missing", nil)).Code != 404 {
		t.Fatal("missing item status")
	}
	w := perform(h, signed(h, "GET", "/internal/wire/v1/feed?language=EN-US&limit=3&fallbackLimit=200", nil))
	if w.Code != 200 || s.feed.Language != "en" || s.feed.Limit != 3 || s.feed.FallbackLimit == nil || *s.feed.FallbackLimit != 200 {
		t.Fatal("feed defaults/query")
	}
	for _, route := range []string{"health", "livez", "readyz"} {
		if perform(h, httptest.NewRequest("GET", "/"+route, nil)).Code != 200 {
			t.Fatal("public health")
		}
	}
	s.err = corpuscore.ErrModerationUnavailable
	if perform(h, httptest.NewRequest("GET", "/readyz", nil)).Code != 503 {
		t.Fatal("readiness moderation")
	}
	s.err = corpuscore.ErrCursorExpired
	if perform(h, signed(h, "GET", "/internal/wire/v1/feed", nil)).Code != 410 {
		t.Fatal("cursor status")
	}
}
func TestCandidateBodyBindingAndCaps(t *testing.T) {
	h, s := testHandler()
	request := corpuscore.CandidateRequest{ActorHashes: []string{"h1:" + strings.Repeat("a", 64)}, Language: "en", Since: h.Now().Add(-time.Hour), Limit: 3}
	body, _ := json.Marshal(request)
	if w := perform(h, signed(h, "POST", "/internal/wire/v1/circle-candidates", body)); w.Code != 200 || s.candidate.Limit != 3 {
		t.Fatalf("valid candidates: %d %s", w.Code, w.Body.String())
	}
	r := signed(h, "POST", "/internal/wire/v1/circle-candidates", body)
	r.Body = http.NoBody
	if perform(h, r).Code != 401 {
		t.Fatal("body substitution accepted")
	}
	for _, change := range []func(*corpuscore.CandidateRequest){func(q *corpuscore.CandidateRequest) { q.ActorHashes = append(q.ActorHashes, q.ActorHashes[0]) }, func(q *corpuscore.CandidateRequest) { q.Limit = 501 }, func(q *corpuscore.CandidateRequest) { q.Since = h.Now().Add(-8 * 24 * time.Hour) }, func(q *corpuscore.CandidateRequest) { q.Since = h.Now().Add(61 * time.Second) }, func(q *corpuscore.CandidateRequest) { q.ActorHashes = []string{"private-did"} }} {
		q := request
		change(&q)
		body, _ := json.Marshal(q)
		if w := perform(h, signed(h, "POST", "/internal/wire/v1/circle-candidates", body)); w.Code != 400 {
			t.Fatalf("invalid candidates accepted %d", w.Code)
		}
	}
	if perform(h, signed(h, "POST", "/internal/wire/v1/circle-candidates", []byte(`{}`))).Code != 400 {
		t.Fatal("missing fields")
	}
}
func TestConfigAndReplayExpiry(t *testing.T) {
	env := map[string]string{"APP_ENV": "dev", "DATABASE_URL": "postgres://localhost/test", "WIRE_CORPUS_EDGE_SHARED_SECRET": strings.Repeat("s", 32), "WIRE_CORPUS_EDGE_ALLOWED_SERVICE_ID": "appview"}
	for _, count := range []string{"0", "9", "not-int"} {
		env["WIRE_CORPUS_EDGE_POSTGRES_MAX_CONNECTIONS"] = count
		c, err := LoadConfig(env)
		if err != nil || c.MaximumConnections < 1 || c.MaximumConnections > 8 {
			t.Fatal("pool bounds")
		}
	}
	for _, key := range []string{"APP_ENV", "DATABASE_URL", "WIRE_CORPUS_EDGE_SHARED_SECRET", "WIRE_CORPUS_EDGE_ALLOWED_SERVICE_ID"} {
		copy := map[string]string{}
		for k, v := range env {
			copy[k] = v
		}
		copy[key] = ""
		if _, err := LoadConfig(copy); err == nil {
			t.Fatal("missing accepted", key)
		}
	}
	guard := NewReplayGuard(1)
	at := time.Unix(1000, 0)
	if !guard.Consume("a", at) || guard.Consume("a", at.Add(60*time.Second)) || !guard.Consume("b", at.Add(61*time.Second)) {
		t.Fatal("replay window boundary")
	}
}
