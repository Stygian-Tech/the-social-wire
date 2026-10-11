package thinappviewcore

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"net/http"
	"net/netip"
	"testing"
)

type thinLocalDNS struct{ addresses []netip.Addr }

func (r thinLocalDNS) LookupNetIP(context.Context, string, string) ([]netip.Addr, error) {
	return r.addresses, nil
}
func thinLocalPolicy(t *testing.T) *gatewaycore.EndpointPolicy {
	t.Helper()
	p, err := gatewaycore.NewEndpointPolicyWithResolver(map[string]string{"APP_ENV": "local", "LOCAL_ATPROTO_ALLOWED_HOSTS": "plc.atmosbox.test,pds1.atmosbox.test"}, thinLocalDNS{[]netip.Addr{netip.MustParseAddr("127.0.0.1")}})
	if err != nil {
		t.Fatal(err)
	}
	return p
}
func TestLocalPDSAuthorityAndDIDWebRemainScoped(t *testing.T) {
	p := thinLocalPolicy(t)
	if got := validatedPDSBase("https://pds1.atmosbox.test/", p); got != "https://pds1.atmosbox.test" {
		t.Fatal(got)
	}
	for _, raw := range []string{"http://pds1.atmosbox.test", "https://pds2.atmosbox.test", "https://user@pds1.atmosbox.test", "https://pds1.atmosbox.test/path", "https://pds1.atmosbox.test?token=x", "https://pds1.atmosbox.test#x", "https://127.0.0.1", "https://nested.example.com"} {
		if validatedPDSBase(raw, p) != "" {
			t.Fatalf("unsafe PDS accepted %s", raw)
		}
	}
	if ValidatePDSBase("https://pds1.atmosbox.test") != "" {
		t.Fatal("public default widened")
	}
	target, err := didDocumentURLWithPolicy("did:web:pds1.atmosbox.test:users:sam", "https://plc.atmosbox.test", p)
	if err != nil || target != "https://pds1.atmosbox.test/users/sam/did.json" {
		t.Fatalf("%s %v", target, err)
	}
	if _, err := didDocumentURL("did:web:pds1.atmosbox.test", "https://plc.directory"); err == nil {
		t.Fatal("default admitted local DID")
	}
}

type localDIDGetter struct {
	endpoint string
	urls     []string
}

func (g *localDIDGetter) Get(_ context.Context, target string, _ http.Header, _, _ int) (int, http.Header, []byte, error) {
	g.urls = append(g.urls, target)
	body, err := json.Marshal(map[string]any{"id": "did:web:pds1.atmosbox.test", "service": []any{map[string]any{"id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": g.endpoint}}})
	return 200, nil, body, err
}
func TestLocalPDSResolutionUsesPolicyForDocumentAndEndpoint(t *testing.T) {
	g := &localDIDGetter{endpoint: "https://pds1.atmosbox.test"}
	p := PDSClient{HTTP: g, Policy: thinLocalPolicy(t)}
	endpoint, err := p.Resolve(context.Background(), "did:web:pds1.atmosbox.test")
	if err != nil || endpoint != g.endpoint || len(g.urls) != 1 || g.urls[0] != "https://pds1.atmosbox.test/.well-known/did.json" {
		t.Fatalf("%s %v %+v", endpoint, err, g.urls)
	}
	p.Invalidate("did:web:pds1.atmosbox.test")
	g.endpoint = "https://pds2.atmosbox.test"
	if _, err := p.Resolve(context.Background(), "did:web:pds1.atmosbox.test"); err == nil {
		t.Fatal("unlisted service endpoint accepted")
	}
}
func TestLocalSnapshotIdentityUsesPolicyWithoutWeakeningSignature(t *testing.T) {
	f := newSnapshotFixture(t, 1)
	f.document["service"].([]any)[0].(map[string]any)["serviceEndpoint"] = "https://pds1.atmosbox.test"
	reader := f.reader()
	reader.PDS.Policy = thinLocalPolicy(t)
	result, err := reader.Read(context.Background(), snapshotFixtureDID, []string{"site.standard.document"})
	if err != nil || result.PDSBase != "https://pds1.atmosbox.test" || len(result.Records) != 1 {
		t.Fatalf("%+v %v", result, err)
	}
	reader.PDS.Policy = nil
	if _, err := reader.Read(context.Background(), snapshotFixtureDID, []string{"site.standard.document"}); err == nil {
		t.Fatal("public snapshot accepted local endpoint")
	}
}
func TestLocalPublicHTTPRejectsUnlistedOrInsecureURLsBeforeResolution(t *testing.T) {
	h := PublicHTTP{Policy: thinLocalPolicy(t)}
	for _, target := range []string{"http://pds1.atmosbox.test/path", "https://pds2.atmosbox.test/path", "https://127.0.0.1/path", "https://pds1.atmosbox.test#fragment"} {
		_, _, _, err := h.Get(context.Background(), target, nil, 1024, 1)
		if err != gatewaycore.ErrInvalidEndpoint {
			t.Fatalf("unsafe request admission %s: %v", target, err)
		}
	}
}
