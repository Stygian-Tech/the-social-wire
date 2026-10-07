package wireworkercore

import (
	"context"
	"fmt"
	"net/http"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

type metadataPublicGetter struct {
	publicationCalls    int
	moderated, mismatch bool
}

func (g *metadataPublicGetter) Get(_ context.Context, raw string, _ http.Header, _ int, _ int) (int, http.Header, []byte, error) {
	did := "did:web:publisher.social"
	if strings.Contains(raw, "getProfile") {
		labels := "[]"
		if g.moderated {
			labels = `[{"val":"spam"}]`
		}
		if g.mismatch {
			did = "did:web:other.social"
		}
		return 200, nil, []byte(fmt.Sprintf(`{"did":%q,"handle":"publisher.social","labels":%s}`, did, labels)), nil
	}
	if strings.Contains(raw, "getRecord") {
		g.publicationCalls++
		return 200, nil, []byte(`{"uri":"at://did:web:publisher.social/site.standard.publication/self","cid":"fixture","value":{"url":"https://publisher.social","name":"Publication"}}`), nil
	}
	return 200, nil, []byte(`{"id":"did:web:publisher.social","service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.publisher.social"}]}`), nil
}

type metadataPublicDNS struct{}

func (metadataPublicDNS) LookupNetIP(context.Context, string, string) ([]netip.Addr, error) {
	return []netip.Addr{netip.MustParseAddr("1.1.1.1")}, nil
}
func TestPublicProfileBindingAndModeration(t *testing.T) {
	g := &metadataPublicGetter{}
	h := EnrichmentHost{ProfileHTTP: g}
	did := "did:web:publisher.social"
	if profile, err := h.fetchProfile(context.Background(), did); err != nil || profile.DID != did {
		t.Fatal(profile, err)
	}
	g.mismatch = true
	if _, err := h.fetchProfile(context.Background(), did); err == nil {
		t.Fatal("accepted mismatched profile")
	}
	g.mismatch = false
	g.moderated = true
	if _, err := h.fetchProfile(context.Background(), did); err == nil {
		t.Fatal("accepted moderated profile")
	}
}
func TestPublicResolverReturnsAcceptedDurablePublicationAndBlobURL(t *testing.T) {
	db := generationDatabase(t)
	g := &metadataPublicGetter{}
	pds := &thinappviewcore.PDSClient{HTTP: g}
	p := NewPublicResolver(db, pds)
	p.DNS = gatewaycore.NewPublicDNSValidator(metadataPublicDNS{}, 1)
	uri := "at://did:web:publisher.social/site.standard.publication/self"
	at := time.Now().UTC()
	t.Cleanup(func() { db.Exec(`DELETE FROM wire_publications WHERE publication_uri=$1`, uri) })
	if metadata, err := p.Resolve(context.Background(), uri, at); err != nil || metadata == nil || metadata.Name != "Publication" {
		t.Fatal(metadata, err)
	}
	if _, err := p.Resolve(context.Background(), uri, at); err != nil || g.publicationCalls != 1 {
		t.Fatal(g.publicationCalls, err)
	}
	if blob, err := p.ResolveBlobURL(context.Background(), "did:web:publisher.social", "blob"); err != nil || blob != "https://pds.publisher.social/xrpc/com.atproto.sync.getBlob?cid=blob&did=did%3Aweb%3Apublisher.social" {
		t.Fatal(blob, err)
	}
	if _, err := p.Resolve(context.Background(), "at://wrong/site.standard.publication/self", at); err == nil {
		t.Fatal("accepted invalid publication")
	}
}
