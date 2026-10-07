package gatewaycore

import (
	"context"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

type resolverTransport func(*http.Request) (*http.Response, error)

func (f resolverTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestRepoResolverCloneAppliesToRecordAndListWithoutChangingOriginal(t *testing.T) {
	var resolves, reads atomic.Int32
	base := &RepoClient{PLCURL: "https://plc.directory", Client: &http.Client{Transport: resolverTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "publisher.social" {
			t.Fatal("cache seam bypassed", r.URL.Host)
		}
		if r.Header.Get("Authorization") != "" || r.Header.Get("DPoP") != "" {
			t.Fatal("public read carried credentials")
		}
		reads.Add(1)
		raw := `{"uri":"at://did:plc:owner/site.standard.document/one","value":{}}`
		if strings.HasSuffix(r.URL.Path, "listRecords") {
			raw = `{"records":[` + raw + `]}`
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(raw))}, nil
	})}}
	clone := base.WithPDSResolver(func(context.Context, string) (string, error) { resolves.Add(1); return "https://publisher.social", nil })
	if _, err := clone.GetRecord(context.Background(), "did:plc:owner", "site.standard.document", "one", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := clone.ListRecords(context.Background(), "did:plc:owner", "site.standard.document", "", 100, false); err != nil {
		t.Fatal(err)
	}
	if resolves.Load() != 2 || reads.Load() != 2 || base.PDSResolver != nil || clone == base || clone.Client != base.Client {
		t.Fatal("clone transport/config ownership changed")
	}
}

func TestRepoResolverCallbackRetainsPublicEndpointValidation(t *testing.T) {
	base := &RepoClient{}
	for _, endpoint := range []string{"http://publisher.social", "https://127.0.0.1", "https://user:secret@publisher.social"} {
		clone := base.WithPDSResolver(func(context.Context, string) (string, error) { return endpoint, nil })
		if _, err := clone.ResolvePDS(context.Background(), "did:plc:owner"); err == nil {
			t.Fatal("unsafe resolver endpoint admitted", endpoint)
		}
	}
}
