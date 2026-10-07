package gatewaycore

// Bounds concurrent DNS admission and rejects an HTTPS endpoint if any answer is special-
// use or private. Address selection is deterministic. Callers must pin the admitted
// address when dialing and revalidate redirects to avoid DNS rebinding.

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
		octets := address.As4()
		firstOctet, secondOctet, thirdOctet := octets[0], octets[1], octets[2]
		if firstOctet == 0 || firstOctet == 10 || firstOctet == 127 || firstOctet >= 224 {
			return false
		}
		if firstOctet == 100 && secondOctet >= 64 && secondOctet <= 127 || firstOctet == 169 && secondOctet == 254 || firstOctet == 172 && secondOctet >= 16 && secondOctet <= 31 || firstOctet == 192 && secondOctet == 168 || firstOctet == 192 && secondOctet == 88 && thirdOctet == 99 || firstOctet == 198 && (secondOctet == 18 || secondOctet == 19) || firstOctet == 192 && secondOctet == 0 && (thirdOctet == 0 || thirdOctet == 2) || firstOctet == 198 && secondOctet == 51 && thirdOctet == 100 || firstOctet == 203 && secondOctet == 0 && thirdOctet == 113 {
			return false
		}
		return true
	}
	octets := address.As16()
	if netip.MustParsePrefix("64:ff9b::/96").Contains(address) {
		return IsPublicAddress(netip.AddrFrom4([4]byte{octets[12], octets[13], octets[14], octets[15]}))
	}
	if netip.MustParsePrefix("64:ff9b:1::/48").Contains(address) || netip.MustParsePrefix("100:0:0:1::/64").Contains(address) {
		return false
	}
	if octets[0]&0xe0 != 0x20 {
		return false
	}
	if octets[0] == 0x20 && octets[1] == 1 && octets[2]&0xfe == 0 {
		if octets[2] == 0 && octets[3] == 1 {
			zero := true
			for _, octet := range octets[4:15] {
				zero = zero && octet == 0
			}
			if zero && (octets[15] == 1 || octets[15] == 2 || octets[15] == 3) {
				return true
			}
		}
		if octets[2] == 0 && octets[3] == 3 || octets[2] == 0 && octets[3] == 4 && octets[4] == 1 && octets[5] == 0x12 || octets[2] == 0 && (octets[3]&0xf0 == 0x20 || octets[3]&0xf0 == 0x30) {
			return true
		}
		return false
	}
	if octets[0] == 0x20 && octets[1] == 1 && octets[2] == 0x0d && octets[3] == 0xb8 || octets[0] == 0x20 && octets[1] == 2 || octets[0] == 0x3f && octets[1] == 0xff && octets[2]&0xf0 == 0 {
		return false
	}
	return true
}

// AddressResolver is the injectable DNS lookup boundary used by public-endpoint admission.
type AddressResolver interface {
	LookupNetIP(context.Context, string, string) ([]netip.Addr, error)
}

// PublicDNSValidator limits concurrent resolutions and admits only endpoints whose entire
// answer set is public.
type PublicDNSValidator struct {
	Resolver  AddressResolver
	admission chan struct{}
}

// NewPublicDNSValidator defaults to net.DefaultResolver and guarantees at least one
// admission slot.
func NewPublicDNSValidator(resolver AddressResolver, maximumConcurrent int) *PublicDNSValidator {
	if resolver == nil {
		resolver = net.DefaultResolver
	}
	return &PublicDNSValidator{resolver, make(chan struct{}, max(1, maximumConcurrent))}
}

// Validate admits an HTTPS hostname within ten seconds and returns a deterministic public
// address. The caller must dial that address and revalidate redirects.
func (validator *PublicDNSValidator) Validate(ctx context.Context, baseURL string) (string, error) {
	uRL, err := url.Parse(baseURL)
	if err != nil || !strings.EqualFold(uRL.Scheme, "https") || uRL.Hostname() == "" {
		return "", ErrInvalidEndpoint
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	select {
	case validator.admission <- struct{}{}:
	default:
		return "", ErrResolutionUnavailable
	}
	defer func() { <-validator.admission }()
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	addresses, err := validator.Resolver.LookupNetIP(ctx, "ip", uRL.Hostname())
	if err != nil {
		return "", ErrResolutionUnavailable
	}
	if len(addresses) == 0 {
		return "", ErrInvalidEndpoint
	}
	values := []string{}
	ipv4Values := []string{}
	for _, address := range addresses {
		if !IsPublicAddress(address) {
			return "", ErrInvalidEndpoint
		}
		values = append(values, address.String())
		if address.Is4() {
			ipv4Values = append(ipv4Values, address.String())
		}
	}
	// Hosted workers have IPv4 egress. Admit the complete answer set before
	// selecting an address, so preferring IPv4 cannot hide a private IPv6 answer.
	if len(ipv4Values) > 0 {
		sort.Strings(ipv4Values)
		return ipv4Values[0], nil
	}
	sort.Strings(values)
	return values[0], nil
}
