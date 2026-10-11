package gatewaycore

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"sort"
	"strings"
	"time"
)

// EndpointPolicy is an immutable, explicitly opted-in local sandbox boundary.
// Unlisted hosts always retain the normal public HTTPS/DNS admission rules.
type EndpointPolicy struct {
	hosts                           map[string]struct{}
	resolver                        AddressResolver
	appViewBase, handleResolverBase string
}

func NewEndpointPolicy(env map[string]string) (*EndpointPolicy, error) {
	return NewEndpointPolicyWithResolver(env, nil)
}

// NewEndpointPolicyWithResolver accepts an owned DNS boundary for deterministic tests.
func NewEndpointPolicyWithResolver(env map[string]string, resolver AddressResolver) (*EndpointPolicy, error) {
	raw := strings.TrimSpace(env["LOCAL_ATPROTO_ALLOWED_HOSTS"])
	if raw == "" {
		if strings.TrimSpace(env["ATPROTO_LOCAL_APPVIEW_URL"])+strings.TrimSpace(env["ATPROTO_LOCAL_HANDLE_RESOLVER_URL"]) != "" {
			return nil, fmt.Errorf("local service overrides require LOCAL_ATPROTO_ALLOWED_HOSTS")
		}
		return nil, nil
	}
	if env["APP_ENV"] != "local" {
		return nil, fmt.Errorf("LOCAL_ATPROTO_ALLOWED_HOSTS requires APP_ENV=local")
	}
	hosts := map[string]struct{}{}
	for _, host := range strings.Split(raw, ",") {
		host = strings.ToLower(strings.TrimSpace(host))
		if host == "" || len(host) > 253 || !strings.HasSuffix(host, ".test") || net.ParseIP(host) != nil {
			return nil, fmt.Errorf("local sandbox hosts must be exact .test DNS hostnames")
		}
		for _, label := range strings.Split(host, ".") {
			if label == "" || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
				return nil, ErrInvalidEndpoint
			}
			for _, c := range label {
				if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
					return nil, ErrInvalidEndpoint
				}
			}
		}
		hosts[host] = struct{}{}
	}
	if resolver == nil {
		resolver = net.DefaultResolver
	}
	policy := &EndpointPolicy{hosts: hosts, resolver: resolver}
	for key, target := range map[string]*string{"ATPROTO_LOCAL_APPVIEW_URL": &policy.appViewBase, "ATPROTO_LOCAL_HANDLE_RESOLVER_URL": &policy.handleResolverBase} {
		raw := strings.TrimSpace(env[key])
		if raw == "" {
			continue
		}
		u, ok := policy.localURL(raw)
		if !ok || u.RawQuery != "" || u.ForceQuery || (u.Path != "" && u.Path != "/") {
			return nil, fmt.Errorf("%s must be an explicitly allowed sandbox HTTPS origin", key)
		}
		*target = strings.TrimRight(u.String(), "/")
	}
	return policy, nil
}

func (p *EndpointPolicy) localURL(raw string) (*url.URL, bool) {
	if p == nil {
		return nil, false
	}
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Scheme != "https" || u.User != nil || u.Fragment != "" || (u.Port() != "" && u.Port() != "443") {
		return nil, false
	}
	_, ok := p.hosts[strings.ToLower(u.Hostname())]
	return u, ok
}

func (p *EndpointPolicy) NormalizeBase(raw string) (string, error) {
	if u, ok := p.localURL(raw); ok {
		u.Host = strings.ToLower(u.Host)
		u.RawQuery = ""
		u.Path = strings.TrimRight(u.Path, "/")
		return u.String(), nil
	}
	return NormalizePublicRemoteBase(raw)
}

// ValidateAddress admits the whole DNS answer set and returns a pinned address.
// Local hosts may resolve only to loopback/RFC1918/ULA, never metadata/link-local.
func (p *EndpointPolicy) ValidateAddress(ctx context.Context, raw string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	u, ok := p.localURL(raw)
	if !ok {
		if _, err := NormalizePublicRemoteBase(raw); err != nil {
			return "", err
		}
		return NewPublicDNSValidator(nil, 64).Validate(ctx, raw)
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	values, err := p.resolver.LookupNetIP(ctx, "ip", u.Hostname())
	if err != nil {
		return "", ErrResolutionUnavailable
	}
	if len(values) == 0 {
		return "", ErrInvalidEndpoint
	}
	addresses := []string{}
	ipv4 := []string{}
	for _, address := range values {
		if !address.IsValid() || address.Zone() != "" || address.Is4In6() || !(address.IsLoopback() || address.IsPrivate()) {
			return "", ErrInvalidEndpoint
		}
		addresses = append(addresses, address.String())
		if address.Is4() {
			ipv4 = append(ipv4, address.String())
		}
	}
	if len(ipv4) > 0 {
		sort.Strings(ipv4)
		return ipv4[0], nil
	}
	sort.Strings(addresses)
	return addresses[0], nil
}

// AppViewBase keeps configured sandbox discovery on the sandbox network.
func (p *EndpointPolicy) AppViewBase() string {
	if p != nil && p.appViewBase != "" {
		return p.appViewBase
	}
	return "https://public.api.bsky.app"
}
func (p *EndpointPolicy) HandleResolverBase() string {
	if p != nil && p.handleResolverBase != "" {
		return p.handleResolverBase
	}
	return "https://public.api.bsky.app"
}
