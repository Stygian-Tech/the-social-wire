package gatewaycore

import (
	"context"
	"net/http"
	"net/netip"
	"testing"
)

type sandboxResolver []netip.Addr

func (r sandboxResolver) LookupNetIP(context.Context, string, string) ([]netip.Addr, error) {
	return r, nil
}
func sandboxPolicy(t *testing.T, addresses ...string) *EndpointPolicy {
	t.Helper()
	values := sandboxResolver{}
	for _, address := range addresses {
		values = append(values, netip.MustParseAddr(address))
	}
	policy, err := NewEndpointPolicyWithResolver(map[string]string{"APP_ENV": "local", "LOCAL_ATPROTO_ALLOWED_HOSTS": "pds1.atmosbox.test,plc.atmosbox.test"}, values)
	if err != nil {
		t.Fatal(err)
	}
	return policy
}

func TestSandboxPolicyRequiresExplicitLocalExactHosts(t *testing.T) {
	for _, environment := range []string{"dev", "prod", ""} {
		if _, err := NewEndpointPolicy(map[string]string{"APP_ENV": environment, "LOCAL_ATPROTO_ALLOWED_HOSTS": "pds1.atmosbox.test"}); err == nil {
			t.Fatal("nonlocal opt-in accepted")
		}
	}
	for _, host := range []string{"*.atmosbox.test", "pds1.atmosbox.test:443", "https://pds1.atmosbox.test", "127.0.0.1", "metadata.google.internal", "pds1.atmosbox.test,", "-bad.test"} {
		if _, err := NewEndpointPolicy(map[string]string{"APP_ENV": "local", "LOCAL_ATPROTO_ALLOWED_HOSTS": host}); err == nil {
			t.Fatalf("invalid host accepted: %s", host)
		}
	}
	empty, err := NewEndpointPolicy(map[string]string{"APP_ENV": "prod"})
	if err != nil || empty != nil {
		t.Fatal("default policy changed")
	}
	policy := sandboxPolicy(t, "127.0.0.1")
	if got, err := policy.NormalizeBase("https://pds1.atmosbox.test/path/?q=x"); err != nil || got != "https://pds1.atmosbox.test/path" {
		t.Fatalf("local normalization: %s %v", got, err)
	}
	for _, raw := range []string{"http://pds1.atmosbox.test", "https://pds2.atmosbox.test", "https://pds1.atmosbox.test.evil.test", "https://pds1.atmosbox.test:8080", "https://user@pds1.atmosbox.test", "https://pds1.atmosbox.test/#fragment", "https://127.0.0.1"} {
		if _, err := policy.NormalizeBase(raw); err == nil {
			t.Fatalf("unsafe endpoint accepted: %s", raw)
		}
	}
	if _, err := NormalizePublicRemoteBase("https://pds1.atmosbox.test"); err == nil {
		t.Fatal("global public admission weakened")
	}
	if _, err := empty.NormalizeBase("https://pds1.atmosbox.test"); err == nil {
		t.Fatal("nil admission weakened")
	}
}

func TestSandboxDNSPinsOnlyEntirePrivateAnswerSets(t *testing.T) {
	for _, addresses := range [][]string{{"127.0.0.1"}, {"10.1.2.3"}, {"::1"}, {"fd12::1"}} {
		if _, err := sandboxPolicy(t, addresses...).ValidateAddress(context.Background(), "https://pds1.atmosbox.test"); err != nil {
			t.Fatalf("sandbox address rejected: %v %v", addresses, err)
		}
	}
	for _, addresses := range [][]string{{}, {"169.254.169.254"}, {"0.0.0.0"}, {"8.8.8.8"}, {"127.0.0.1", "8.8.8.8"}, {"fe80::1"}, {"::ffff:127.0.0.1"}} {
		if _, err := sandboxPolicy(t, addresses...).ValidateAddress(context.Background(), "https://pds1.atmosbox.test"); err == nil {
			t.Fatalf("unsafe DNS admitted: %v", addresses)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := sandboxPolicy(t, "127.0.0.1").ValidateAddress(ctx, "https://pds1.atmosbox.test"); err == nil {
		t.Fatal("canceled admission succeeded")
	}
}

func TestSandboxTransportKeepsTLSAndRedirectBoundaries(t *testing.T) {
	client := NewHTTPClientWithPolicy(sandboxPolicy(t, "127.0.0.1"))
	transport := client.Transport.(*http.Transport)
	if transport.TLSClientConfig.InsecureSkipVerify || transport.Proxy != nil {
		t.Fatal("sandbox bypasses TLS or proxy admission")
	}
	if client.CheckRedirect(&http.Request{}, nil) != http.ErrUseLastResponse {
		t.Fatal("credentials can follow redirects")
	}
	verifier := TokenVerifier{Policy: sandboxPolicy(t, "127.0.0.1"), Client: &http.Client{Transport: fixtureTransport(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: http.NoBody}, nil
	})}}
	if _, status, err := verifier.fetch(context.Background(), "https://plc.atmosbox.test/did:plc:test", 100); err != nil || status != 200 {
		t.Fatalf("local auth discovery blocked: %v", err)
	}
	if _, _, err := verifier.fetch(context.Background(), "https://unlisted.atmosbox.test/x", 100); err == nil {
		t.Fatal("unlisted auth target admitted")
	}
}
