package thinappviewcore

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

type didGetter struct {
	calls         int
	urls          []string
	wrongIdentity bool
}

func (g *didGetter) Get(_ context.Context, u string, _ http.Header, _ int, _ int) (int, http.Header, []byte, error) {
	g.calls++
	g.urls = append(g.urls, u)
	did := "did:web:publisher.social"
	if g.wrongIdentity {
		did = "did:web:other.social"
	}
	return 200, nil, []byte(fmt.Sprintf(`{"id":%q,"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.publisher.social"}]}`, did)), nil
}
func TestDIDWebResolutionCacheExpiresAndInvalidates(t *testing.T) {
	g := &didGetter{}
	now := time.Unix(100, 0)
	p := PDSClient{HTTP: g, Now: func() time.Time { return now }, CacheTTL: time.Minute}
	for i := 0; i < 2; i++ {
		endpoint, err := p.Resolve(context.Background(), "did:web:publisher.social")
		if err != nil || endpoint != "https://pds.publisher.social" {
			t.Fatalf("endpoint=%s err=%v", endpoint, err)
		}
	}
	if g.calls != 1 || g.urls[0] != "https://publisher.social/.well-known/did.json" {
		t.Fatal(g)
	}
	now = now.Add(time.Minute)
	if _, err := p.Resolve(context.Background(), "did:web:publisher.social"); err != nil {
		t.Fatal(err)
	}
	if g.calls != 2 {
		t.Fatal("expired endpoint reused")
	}
	p.Invalidate("did:web:publisher.social")
	if _, err := p.Resolve(context.Background(), "did:web:publisher.social"); err != nil {
		t.Fatal(err)
	}
	if g.calls != 3 {
		t.Fatal("invalidated endpoint reused")
	}
}
func TestDIDDocumentBindingAndWebPath(t *testing.T) {
	p := PDSClient{HTTP: &didGetter{wrongIdentity: true}}
	if _, err := p.Resolve(context.Background(), "did:web:publisher.social"); err == nil {
		t.Fatal("foreign DID accepted")
	}
	u, err := didDocumentURL("did:web:publisher.social:users:sam", "https://plc.directory")
	if err != nil || u != "https://publisher.social/users/sam/did.json" {
		t.Fatalf("%s %v", u, err)
	}
	for _, did := range []string{"did:web:localhost", "did:web:publisher.social:%2fprivate", "did:web:publisher.social:..", "did:key:123"} {
		if _, err := didDocumentURL(did, "https://plc.directory"); err == nil {
			t.Fatalf("unsafe DID accepted %s", did)
		}
	}
}

func TestPDSRecordResponseErrorsPreserveSafeClassification(t *testing.T) {
	for _, test := range []struct {
		status int
		body   string
		code   string
	}{{400, `{"error":"RecordNotFound","message":"secret"}`, "RecordNotFound"}, {404, `{}`, ""}, {429, `{"error":"RateLimitExceeded"}`, "RateLimitExceeded"}, {503, `{"error":"secret url https://host/path"}`, ""}} {
		err := pdsRecordError(test.status, []byte(test.body))
		response, ok := err.(*PDSRecordResponseError)
		if !ok || response.Status != test.status || response.Code != test.code {
			t.Fatalf("%+v", err)
		}
		if strings.Contains(err.Error(), "secret") {
			t.Fatal("unsafe response leaked")
		}
	}
}
