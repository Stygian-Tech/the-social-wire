package corpuscore

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestRemoteSigningTargetsAndBody(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	secret := strings.Repeat("s", 32)
	count := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count++
		headers := wirecore.CorpusServiceHeaders{ServiceID: r.Header.Get(wirecore.CorpusServiceHeader), Timestamp: r.Header.Get(wirecore.CorpusTimestampHeader), Nonce: r.Header.Get(wirecore.CorpusNonceHeader), Signature: r.Header.Get(wirecore.CorpusSignatureHeader)}
		if digest := r.Header.Get(wirecore.CorpusBodyDigestHeader); digest != "" {
			headers.BodyDigest = &digest
		}
		if err := wirecore.VerifyCorpusRequest([]byte(secret), "appview", r.Method, r.URL.RequestURI(), headers, now); err != nil {
			t.Error(err)
			w.WriteHeader(401)
			return
		}
		if r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" || r.Header.Get("DPoP") != "" {
			t.Error("viewer credentials forwarded")
		}
		w.Header().Set("X-Wire-Corpus-Contract", "3")
		switch r.URL.Path {
		case "/internal/wire/v1/contract":
			w.Write([]byte(`{"contractVersion":3}`))
		case "/readyz":
			w.Write([]byte(`{"service":"wire-corpus-edge","status":"ready"}`))
		case "/internal/wire/v1/feed":
			if r.URL.Query().Get("generationId") != "generation" || r.URL.Query().Get("fallbackLimit") != "5000" {
				t.Error(r.URL.Query())
			}
			data, _ := MarshalHTTP(Page{GenerationID: "generation", GeneratedAt: now, Language: "en", Rows: []Row{}, Exhausted: true})
			w.Write(data)
		case "/internal/wire/v1/circle-candidates":
			body, _ := io.ReadAll(r.Body)
			if headers.BodyDigest == nil || *headers.BodyDigest != wirecore.CorpusBodyDigest(body) {
				t.Error("body digest")
			}
			var q CandidateRequest
			if json.Unmarshal(body, &q) != nil || q.Limit != 3 {
				t.Error("request shape")
			}
			data, _ := MarshalHTTP(CandidateResponse{GeneratedAt: now, Stories: []CandidateStory{}})
			w.Write(data)
		case "/internal/wire/v1/item":
			w.WriteHeader(404)
		default:
			t.Error(r.URL.Path)
			w.WriteHeader(500)
		}
	}))
	defer server.Close()
	remote := NewRemoteStore(RemoteConfig{server.URL, "appview", secret}, server.Client())
	remote.Now = func() time.Time { return now }
	ctx := context.Background()
	if err := remote.Ping(ctx); err != nil {
		t.Fatal(err)
	}
	if err := remote.RequireFreshBaseline(ctx, now); err != nil {
		t.Fatal(err)
	}
	id := "generation"
	limit := 5000
	if page, err := remote.Feed(ctx, FeedQuery{Language: "en", GenerationID: &id, Limit: 100, FallbackLimit: &limit}, now); err != nil || page.GenerationID != id {
		t.Fatal(page, err)
	}
	if _, err := remote.CircleCandidates(ctx, CandidateRequest{ActorHashes: []string{"h1:" + strings.Repeat("a", 64)}, Language: "en", Since: now, Limit: 3}, now); err != nil {
		t.Fatal(err)
	}
	if item, err := remote.Item(ctx, "missing", now); err != nil || item != nil {
		t.Fatal(item, err)
	}
	if count != 5 {
		t.Fatal(count)
	}
}
func TestRemoteFailClosedBoundsRedirectsAndContracts(t *testing.T) {
	for _, test := range []struct {
		name         string
		status       int
		header, body string
		want         error
	}{{"missing-contract", 200, "", `{"contractVersion":3}`, ErrContractMismatch}, {"wrong-contract", 200, "2", `{"contractVersion":3}`, ErrContractMismatch}, {"wrong-body", 200, "3", `{"contractVersion":2}`, ErrContractMismatch}, {"oversized", 200, "3", strings.Repeat("a", 65), ErrUnavailable}, {"expired", 410, "", "", ErrCursorExpired}, {"unavailable", 503, "", "", ErrUnavailable}, {"null", 200, "3", "null", ErrContractMismatch}, {"redirect", 302, "3", "", ErrUnavailable}} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("X-Wire-Corpus-Contract", test.header)
				w.Header().Set("Location", "https://example.com/private")
				w.WriteHeader(test.status)
				w.Write([]byte(test.body))
			}))
			defer server.Close()
			remote := NewRemoteStore(RemoteConfig{server.URL, "appview", strings.Repeat("s", 32)}, server.Client())
			remote.MaximumResponseBytes = 64
			if err := remote.Ping(context.Background()); !errors.Is(err, test.want) {
				t.Fatal(err)
			}
		})
	}
}
func TestRemoteOriginConfiguration(t *testing.T) {
	for _, test := range []struct {
		env, base string
		allowed   bool
	}{{"prod", "https://corpus.example", true}, {"prod", "http://corpus.example", false}, {"dev", "http://wire-corpus-edge.railway.internal", true}, {"prod", "http://wire-corpus-edge.railway.internal", false}, {"local", "http://127.0.0.1:1234", true}, {"dev", "http://127.0.0.1:1234", false}, {"prod", "https://user:secret@corpus.example", false}, {"prod", "https://corpus.example/path", false}, {"prod", "https://corpus.example?x=1", false}, {"prod", "https://corpus.example#x", false}} {
		env := map[string]string{"APP_ENV": test.env, "WIRE_CORPUS_EDGE_BASE_URL": test.base, "WIRE_CORPUS_EDGE_SERVICE_ID": "appview", "WIRE_CORPUS_EDGE_HMAC_SECRET": strings.Repeat("s", 32)}
		config, err := RemoteConfigFromEnvironment(env)
		if (err == nil) != test.allowed || test.allowed && config == nil {
			t.Fatal(test, err)
		}
	}
	if value, err := RemoteConfigFromEnvironment(nil); value != nil || err != nil {
		t.Fatal(value, err)
	}
}
