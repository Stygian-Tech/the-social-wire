package topicreadcore

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

type fixedResolver string

func (r fixedResolver) ResolvePDS(context.Context, string) (string, error) { return string(r), nil }

type moderationHTTP struct {
	mu                           sync.Mutex
	calls                        []string
	fail, truncated, emptyCursor bool
}

func (m *moderationHTTP) Get(ctx context.Context, target string, h http.Header, max, redirects int) (int, http.Header, []byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls = append(m.calls, target)
	if m.fail {
		return 503, nil, nil, nil
	}
	if max != 2<<20 || redirects != 0 {
		return 0, nil, nil, errors.New("transport bounds")
	}
	u, _ := url.Parse(target)
	method := strings.TrimPrefix(u.Path, "/xrpc/")
	doc := map[string]any{}
	if method == "app.bsky.graph.getList" {
		if h.Get("Authorization") != "" || h.Get("DPoP") != "" {
			return 0, nil, nil, errors.New("credentials escaped")
		}
		doc["items"] = []any{map[string]any{"subject": map[string]any{"did": "did:example:list"}}}
		if m.emptyCursor {
			doc["cursor"] = ""
		}
	} else {
		index := -1
		for i, v := range ModerationMethods {
			if method == v {
				index = i
			}
		}
		if index < 0 || h.Get("Authorization") != "Bearer private" || h.Get("DPoP") != []string{"p0", "p1", "p2", "p3", "p4"}[index] {
			return 0, nil, nil, errors.New("proof binding")
		}
		if index > 0 && u.Query().Get("limit") != "100" {
			return 0, nil, nil, errors.New("limit")
		}
		switch index {
		case 0:
			doc["preferences"] = []any{map[string]any{"$type": "app.bsky.actor.defs#mutedWordsPref", "items": []any{map[string]any{"value": " SECRET "}, map[string]any{"value": "expired", "expiresAt": nil}}}, map[string]any{"$type": "app.bsky.actor.defs#interestsPref", "tags": []any{" Go "}}}
		case 1:
			doc["blocks"] = []any{map[string]any{"did": "did:example:block"}}
		case 2:
			doc["mutes"] = []any{map[string]any{"did": "did:example:mute"}}
		case 3, 4:
			doc["lists"] = []any{map[string]any{"uri": "at://did:example:owner/app.bsky.graph.list/a"}}
		}
		if m.truncated && index == 1 {
			doc["cursor"] = nil
		}
	}
	body, _ := json.Marshal(doc)
	return 200, nil, body, nil
}
func TestModerationProofsFilteringAndStaleBoundary(t *testing.T) {
	now := time.Now()
	http := &moderationHTTP{}
	m := NewModerationService(fixedResolver("https://pds.example"), http)
	a := &gatewaycore.AuthContext{DID: "did:example:viewer", Authorization: "Bearer private"}
	s, e := m.Require(context.Background(), a, "p0,p1,p2,p3,p4", now)
	if e != nil {
		t.Fatal(e)
	}
	for _, did := range []string{"did:example:block", "did:example:mute", "did:example:list"} {
		if s.Allows(did, "Allowed", nil, nil) {
			t.Fatal(did)
		}
	}
	if s.Allows("other", "secret disclosure", nil, nil) || !s.InterestTags["go"] || len(s.MutedWords) != 1 || len(http.calls) != 6 {
		t.Fatal(s, http.calls)
	}
	http.fail = true
	if _, e = m.Require(context.Background(), a, "", now.Add(6*time.Minute)); e != nil {
		t.Fatal(e)
	}
	if _, e = m.Require(context.Background(), a, "", now.Add(31*time.Minute)); !errors.Is(e, ErrModerationUnavailable) {
		t.Fatal(e)
	}
	if _, e = m.Require(context.Background(), nil, "", now); e != nil {
		t.Fatal(e)
	}
}
func TestModerationIncompletePagesFailClosed(t *testing.T) {
	for _, mode := range []string{"private-null", "public-empty"} {
		t.Run(mode, func(t *testing.T) {
			h := &moderationHTTP{truncated: mode == "private-null", emptyCursor: mode == "public-empty"}
			m := NewModerationService(fixedResolver("https://pds.example"), h)
			_, e := m.Require(context.Background(), &gatewaycore.AuthContext{DID: "did:example:viewer", Authorization: "Bearer private"}, "p0,p1,p2,p3,p4", time.Now())
			if !errors.Is(e, ErrModerationUnavailable) {
				t.Fatal(e)
			}
			if mode == "public-empty" && len(h.calls) != 25 {
				t.Fatal(len(h.calls))
			}
		})
	}
}
