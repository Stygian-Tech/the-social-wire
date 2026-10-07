package gatewaycore

import (
	"context"
	"errors"
	"net/netip"
	"testing"
)

type familyResolver []netip.Addr

func (resolver familyResolver) LookupNetIP(context.Context, string, string) ([]netip.Addr, error) {
	return resolver, nil
}

func TestPublicDNSSelectsReachableFamilyWithoutWeakeningAdmission(t *testing.T) {
	for _, test := range []struct {
		answers  []string
		want     string
		rejected bool
	}{
		{[]string{"2606:4700::1111", "8.8.8.8"}, "8.8.8.8", false},
		{[]string{"2606:4700::1111"}, "2606:4700::1111", false},
		{[]string{"8.8.8.8", "fc00::1"}, "", true},
		{[]string{"2606:4700::1111", "127.0.0.1"}, "", true},
	} {
		resolver := familyResolver{}
		for _, answer := range test.answers {
			resolver = append(resolver, netip.MustParseAddr(answer))
		}
		selected, err := NewPublicDNSValidator(resolver, 1).Validate(context.Background(), "https://publisher.example/feed")
		if selected != test.want || (test.rejected && !errors.Is(err, ErrInvalidEndpoint)) || (!test.rejected && err != nil) {
			t.Fatalf("%v: %q %v", test.answers, selected, err)
		}
	}
}
