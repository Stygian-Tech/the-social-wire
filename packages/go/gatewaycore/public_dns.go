package gatewaycore

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"net/url"
	"sort"
	"strings"
	"time"
)

var (
	ErrInvalidEndpoint       = errors.New("invalid public HTTPS endpoint")
	ErrResolutionUnavailable = errors.New("public DNS resolution unavailable")
)

// IsPublicAddress mirrors the gateway's explicit IANA allow/exclusion policy.
// net.IP.IsGlobalUnicast also accepts private addresses, so it is insufficient.
func IsPublicAddress(address netip.Addr) bool {
	if !address.IsValid() || address.Zone() != "" {
		return false
	}
	if address.Is4In6() {
		return false
	}
	if address.Is4() {
		b := address.As4()
		a, c, d := b[0], b[1], b[2]
		if a == 0 || a == 10 || a == 127 || a >= 224 {
			return false
		}
		if a == 100 && c >= 64 && c <= 127 || a == 169 && c == 254 || a == 172 && c >= 16 && c <= 31 || a == 192 && c == 168 || a == 192 && c == 88 && d == 99 || a == 198 && (c == 18 || c == 19) || a == 192 && c == 0 && (d == 0 || d == 2) || a == 198 && c == 51 && d == 100 || a == 203 && c == 0 && d == 113 {
			return false
		}
		return true
	}
	b := address.As16()
	if netip.MustParsePrefix("64:ff9b::/96").Contains(address) {
		return IsPublicAddress(netip.AddrFrom4([4]byte{b[12], b[13], b[14], b[15]}))
	}
	if netip.MustParsePrefix("64:ff9b:1::/48").Contains(address) || netip.MustParsePrefix("100:0:0:1::/64").Contains(address) {
		return false
	}
	if b[0]&0xe0 != 0x20 {
		return false
	}
	if b[0] == 0x20 && b[1] == 1 && b[2]&0xfe == 0 {
		if b[2] == 0 && b[3] == 1 {
			zero := true
			for _, v := range b[4:15] {
				zero = zero && v == 0
			}
			if zero && (b[15] == 1 || b[15] == 2 || b[15] == 3) {
				return true
			}
		}
		if b[2] == 0 && b[3] == 3 || b[2] == 0 && b[3] == 4 && b[4] == 1 && b[5] == 0x12 || b[2] == 0 && (b[3]&0xf0 == 0x20 || b[3]&0xf0 == 0x30) {
			return true
		}
		return false
	}
	if b[0] == 0x20 && b[1] == 1 && b[2] == 0x0d && b[3] == 0xb8 || b[0] == 0x20 && b[1] == 2 || b[0] == 0x3f && b[1] == 0xff && b[2]&0xf0 == 0 {
		return false
	}
	return true
}

type AddressResolver interface {
	LookupNetIP(context.Context, string, string) ([]netip.Addr, error)
}
type PublicDNSValidator struct {
	Resolver  AddressResolver
	admission chan struct{}
}

func NewPublicDNSValidator(resolver AddressResolver, maximumConcurrent int) *PublicDNSValidator {
	if resolver == nil {
		resolver = net.DefaultResolver
	}
	return &PublicDNSValidator{resolver, make(chan struct{}, max(1, maximumConcurrent))}
}
func (v *PublicDNSValidator) Validate(ctx context.Context, baseURL string) (string, error) {
	u, err := url.Parse(baseURL)
	if err != nil || !strings.EqualFold(u.Scheme, "https") || u.Hostname() == "" {
		return "", ErrInvalidEndpoint
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	select {
	case v.admission <- struct{}{}:
	default:
		return "", ErrResolutionUnavailable
	}
	defer func() { <-v.admission }()
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	addresses, err := v.Resolver.LookupNetIP(ctx, "ip", u.Hostname())
	if err != nil {
		return "", ErrResolutionUnavailable
	}
	if len(addresses) == 0 {
		return "", ErrInvalidEndpoint
	}
	values := []string{}
	for _, a := range addresses {
		if !IsPublicAddress(a) {
			return "", ErrInvalidEndpoint
		}
		values = append(values, a.String())
	}
	sort.Strings(values)
	return values[0], nil
}
