package publicationcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type localDiscoveryTransport struct {
	t        *testing.T
	followed bool
}

func (f *localDiscoveryTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	body := `{"records":[]}`
	switch r.URL.Host {
	case "plc.atmosbox.test":
		body = `{"service":[{"id":"#atproto_pds","serviceEndpoint":"https://pds1.atmosbox.test"}]}`
	case "pds1.atmosbox.test":
	case "appview.atmosbox.test":
		if r.URL.Path != "/xrpc/app.bsky.graph.getFollows" {
			f.t.Fatal("unexpected discovery request")
		}
		f.followed = true
		body = `{"follows":[]}`
	default:
		f.t.Fatal("hosted request escaped sandbox", r.URL.Host)
	}
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
}
func TestFollowingDiscoveryUsesConfiguredSandboxAppView(t *testing.T) {
	policy, err := gatewaycore.NewEndpointPolicy(map[string]string{"APP_ENV": "local", "LOCAL_ATPROTO_ALLOWED_HOSTS": "appview.atmosbox.test,pds1.atmosbox.test,plc.atmosbox.test", "ATPROTO_LOCAL_APPVIEW_URL": "https://appview.atmosbox.test"})
	if err != nil {
		t.Fatal(err)
	}
	transport := &localDiscoveryTransport{t: t}
	client := &http.Client{Transport: transport}
	repo := &gatewaycore.RepoClient{Policy: policy, Client: client, PLCURL: "https://plc.atmosbox.test"}
	FollowDiscovery(context.Background(), repo, client, "did:plc:abcdefghijklmnopqrstuvwx", time.Now())
	if !transport.followed {
		t.Fatal("sandbox follows not queried")
	}
}
