package edge

import (
	"context"
	"encoding/json"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
)

type financeSourceFixture struct {
	*fixtureStore
	calls    int
	response corpuscore.FinanceSourceResponse
}

func (s *financeSourceFixture) FinanceSource(context.Context, corpuscore.FinanceSourceRequest, time.Time) (corpuscore.FinanceSourceResponse, error) {
	s.calls++
	return s.response, s.err
}

func TestFinanceSourceAuthenticatedContractAndReplay(t *testing.T) {
	h, base := testHandler()
	store := &financeSourceFixture{fixtureStore: base}
	h.Store = store
	body := []byte(`{"language":"en"}`)
	req := signed(h, "POST", corpuscore.FinanceSourcePath, body)
	if got := perform(h, req); got.Code != 200 || got.Header().Get("X-Wire-Corpus-Contract") != "3" {
		t.Fatal(got.Code, got.Body.String())
	}
	req.Body = io.NopCloser(strings.NewReader(string(body)))
	if got := perform(h, req); got.Code != 401 || !strings.Contains(got.Body.String(), "Unauthorized") {
		t.Fatal("replay", got.Code)
	}
	tampered := signed(h, "POST", corpuscore.FinanceSourcePath, body)
	tampered.Body = io.NopCloser(strings.NewReader(`{"language":"es"}`))
	if got := perform(h, tampered); got.Code != 401 {
		t.Fatal("body digest", got.Code)
	}
	for _, header := range []string{"Authorization", "Cookie", "DPoP"} {
		req := signed(h, "POST", corpuscore.FinanceSourcePath, body)
		req.Header.Set(header, "private")
		if got := perform(h, req); got.Code != 401 {
			t.Fatal(header, got.Code)
		}
	}
	if store.calls != 1 {
		t.Fatal("unauthorized request reached source", store.calls)
	}
}

func TestFinanceSourceBoundsAndErrors(t *testing.T) {
	for _, body := range []string{`null`, `{}`, `{"language":""}`, `{"language":"en","unknown":true}`, `{"language":"en","knownGenerationRevision":"invalid"}`, `{"language":"en"} {}`} {
		h, base := testHandler()
		store := &financeSourceFixture{fixtureStore: base}
		h.Store = store
		if got := perform(h, signed(h, "POST", corpuscore.FinanceSourcePath, []byte(body))); got.Code != 400 || store.calls != 0 {
			t.Fatal(body, got.Code, store.calls)
		}
	}
	h, base := testHandler()
	store := &financeSourceFixture{fixtureStore: base}
	h.Store = store
	store.err = corpuscore.ErrModerationUnavailable
	if got := perform(h, signed(h, "POST", corpuscore.FinanceSourcePath, []byte(`{"language":"en"}`))); got.Code != 503 || !strings.Contains(got.Body.String(), "ModerationUnavailable") {
		t.Fatal(got.Code, got.Body.String())
	}
	store.err = nil
	store.response.Generation = &corpuscore.FinanceGeneration{Language: strings.Repeat("x", 8<<20)}
	got := perform(h, signed(h, "POST", corpuscore.FinanceSourcePath, []byte(`{"language":"en"}`)))
	var envelope map[string]string
	if got.Code != 503 || json.Unmarshal(got.Body.Bytes(), &envelope) != nil || envelope["error"] != "UpstreamUnavailable" {
		t.Fatal("response limit", got.Code)
	}
	if got.Body.Len() > 1024 {
		t.Fatal("oversized source escaped response cap")
	}
}
