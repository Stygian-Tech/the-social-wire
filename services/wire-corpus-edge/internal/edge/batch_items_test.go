package edge

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type batchFixture struct {
	*fixtureStore
	calls int
	ids   []string
}

func (s *batchFixture) Items(_ context.Context, ids []string, _ time.Time) ([]corpuscore.Item, error) {
	s.calls++
	s.ids = ids
	return []corpuscore.Item{{Item: wirecore.FeedItem{ItemID: ids[len(ids)-1], Title: "Current", Reasons: []wirecore.ReasonCode{}, Provenance: []string{}}}}, s.err
}
func batchHandler() (*Handler, *batchFixture) {
	h, f := testHandler()
	s := &batchFixture{fixtureStore: f}
	h.Store = s
	return h, s
}
func TestBatchItemsAuthenticationAndCurrentResults(t *testing.T) {
	h, s := batchHandler()
	body := []byte(`{"itemIds":["missing","current"]}`)
	request := signed(h, "POST", corpuscore.BatchItemsPath, body)
	response := perform(h, request)
	var value corpuscore.ItemsResponse
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &value) != nil || len(value.Items) != 1 || value.Items["current"].Item.Title != "Current" || s.calls != 1 {
		t.Fatalf("%d %s calls=%d", response.Code, response.Body, s.calls)
	}
	if timings := response.Header().Get("Server-Timing"); !strings.Contains(timings, "db-acquisition;dur=") || !strings.Contains(timings, "db-query;dur=") {
		t.Fatal("missing local DB phase timings", timings)
	}
	// Reuse the original signed nonce with a readable body: reject replay.
	request.Body = io.NopCloser(strings.NewReader(string(body)))
	if got := perform(h, request).Code; got != 401 {
		t.Fatal("replay", got)
	}
	tampered := signed(h, "POST", corpuscore.BatchItemsPath, body)
	tampered.Body = io.NopCloser(strings.NewReader(`{"itemIds":["changed"]}`))
	if got := perform(h, tampered).Code; got != 401 {
		t.Fatal("tamper", got)
	}
	for _, header := range []string{"Authorization", "Cookie", "DPoP"} {
		request := signed(h, "POST", corpuscore.BatchItemsPath, body)
		request.Header.Set(header, "private")
		if got := perform(h, request).Code; got != 401 {
			t.Fatal(header, got)
		}
	}
	if s.calls != 1 {
		t.Fatal("unauthorized request reached store", s.calls)
	}
}
func TestBatchItemsBoundsAndFailure(t *testing.T) {
	for _, body := range []string{`null`, `{}`, `{"itemIds":null}`, `{"itemIds":[]}`, `{"itemIds":[""]}`, `{"itemIds":["a","a"]}`, `{"itemIds":["a"],"unexpected":true}`, `{"itemIds":["a"]} {}`} {
		h, s := batchHandler()
		if got := perform(h, signed(h, "POST", corpuscore.BatchItemsPath, []byte(body))).Code; got != 400 || s.calls != 0 {
			t.Fatalf("%s %d calls=%d", body, got, s.calls)
		}
	}
	for _, size := range []int{100, 101} {
		ids := make([]string, size)
		for i := range ids {
			ids[i] = strings.Repeat("a", i+1)
		}
		body, _ := json.Marshal(corpuscore.ItemsRequest{ItemIDs: ids})
		h, _ := batchHandler()
		got := perform(h, signed(h, "POST", corpuscore.BatchItemsPath, body)).Code
		want := http.StatusOK
		if size == 101 {
			want = 400
		}
		if got != want {
			t.Fatal(size, got)
		}
	}
	h, s := batchHandler()
	s.err = corpuscore.ErrModerationUnavailable
	if got := perform(h, signed(h, "POST", corpuscore.BatchItemsPath, []byte(`{"itemIds":["a"]}`))).Code; got != 503 {
		t.Fatal("stale baseline", got)
	}
	h, _ = batchHandler()
	if got := perform(h, signed(h, "POST", corpuscore.BatchItemsPath, []byte(strings.Repeat("x", (32<<10)+1)))).Code; got != 413 {
		t.Fatal("body bound", got)
	}
}

func TestBatchXRPCErrorsMatchDeclaredContract(t *testing.T) {
	for _, test := range []struct {
		name   string
		err    error
		status int
		code   string
	}{
		{"stale baseline", corpuscore.ErrModerationUnavailable, 503, "ModerationUnavailable"},
		{"unavailable", corpuscore.ErrUnavailable, 503, "UpstreamUnavailable"},
		{"contract mismatch", corpuscore.ErrContractMismatch, 503, "UpstreamUnavailable"},
		{"unexpected failure", fmt.Errorf("test failure"), 500, "InternalServerError"},
	} {
		t.Run(test.name, func(t *testing.T) {
			h, s := batchHandler()
			s.err = test.err
			w := perform(h, signed(h, "POST", corpuscore.BatchItemsPath, []byte(`{"itemIds":["a"]}`)))
			var body map[string]string
			if w.Code != test.status || json.Unmarshal(w.Body.Bytes(), &body) != nil || body["error"] != test.code {
				t.Fatal(w.Code, w.Body)
			}
		})
	}
	h, _ := batchHandler()
	for _, test := range []struct {
		body       []byte
		authorized bool
		status     int
		code       string
	}{
		{[]byte(`{"itemIds":[]}`), true, 400, "InvalidRequest"},
		{[]byte(`{"itemIds":["a","a"]}`), true, 400, "InvalidRequest"},
		{[]byte(`{"itemIds":["a"]}`), false, 401, "Unauthorized"},
	} {
		request := signed(h, "POST", corpuscore.BatchItemsPath, test.body)
		if !test.authorized {
			request.Header.Del(wirecore.CorpusSignatureHeader)
		}
		w := perform(h, request)
		var body map[string]string
		if w.Code != test.status || json.Unmarshal(w.Body.Bytes(), &body) != nil || body["error"] != test.code {
			t.Fatal(w.Code, w.Body)
		}
	}
}

func TestBatchSerializationFailureUsesXRPCError(t *testing.T) {
	invalidTime := time.Date(10000, 1, 1, 0, 0, 0, 0, time.UTC)
	writer := httptest.NewRecorder()
	writeBatchItems(writer, corpuscore.ItemsResponse{Items: map[string]corpuscore.Item{"a": {Item: wirecore.FeedItem{PublishedAt: &invalidTime}}}})
	var body map[string]string
	if writer.Code != 500 || json.Unmarshal(writer.Body.Bytes(), &body) != nil || body["error"] != "InternalServerError" {
		t.Fatal(writer.Code, writer.Body)
	}
}
