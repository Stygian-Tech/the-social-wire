package gatewaycore

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"errors"
	"net/netip"
	"testing"

	jose "github.com/go-jose/go-jose/v4"
)

type fixtureResolver []netip.Addr

func (r fixtureResolver) LookupNetIP(context.Context, string, string) ([]netip.Addr, error) {
	return r, nil
}
func TestPublicAddressPolicy(t *testing.T) {
	for _, value := range []string{"8.8.8.8", "2606:4700:4700::1111", "2001:3::1", "64:ff9b::808:808"} {
		if !IsPublicAddress(netip.MustParseAddr(value)) {
			t.Error("rejected public", value)
		}
	}
	for _, value := range []string{"127.0.0.1", "10.0.0.1", "100.64.0.1", "169.254.169.254", "192.0.2.1", "203.0.113.1", "::1", "::ffff:127.0.0.1", "2001:db8::1", "2002:808:808::1", "3fff::1", "64:ff9b::a00:1"} {
		if IsPublicAddress(netip.MustParseAddr(value)) {
			t.Error("accepted special-use", value)
		}
	}
}
func TestMixedDNSAnswersFailClosed(t *testing.T) {
	v := NewPublicDNSValidator(fixtureResolver{netip.MustParseAddr("8.8.8.8"), netip.MustParseAddr("10.0.0.1")}, 8)
	if _, err := v.Validate(context.Background(), "https://example.com"); !errors.Is(err, ErrInvalidEndpoint) {
		t.Fatal(err)
	}
}
func TestPayloadInspectionRejectsNonObjects(t *testing.T) {
	for _, payload := range []string{"null", "[]", "invalid"} {
		if _, err := DecodePayload(Base64URLEncode([]byte(`{"alg":"ES256"}`)) + "." + Base64URLEncode([]byte(payload)) + ".AA"); err == nil {
			t.Fatal("accepted", payload)
		}
	}
}

func TestPayloadInspectionUsesJOSEAndRejectsUnsignedTokens(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.ES256, Key: key}, nil)
	if err != nil {
		t.Fatal(err)
	}
	signed, err := signer.Sign([]byte(`{"sub":"did:plc:viewer","counter":9007199254740991}`))
	if err != nil {
		t.Fatal(err)
	}
	token, err := signed.CompactSerialize()
	if err != nil {
		t.Fatal(err)
	}
	claims, err := DecodePayload(token)
	if err != nil || string(claims["counter"]) != "9007199254740991" {
		t.Fatal(claims, err)
	}
	unsigned := Base64URLEncode([]byte(`{"alg":"none"}`)) + "." + Base64URLEncode([]byte(`{"sub":"did:plc:viewer"}`)) + "."
	if _, err := DecodePayload(unsigned); err == nil {
		t.Fatal("unsigned JOSE token accepted")
	}
}
