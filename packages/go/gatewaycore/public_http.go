package gatewaycore

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// NormalizePublicRemoteBase validates the authority before any credentials are
// attached. DNS admission is a separate pinned-dial check, not URL validation.
func NormalizePublicRemoteBase(raw string) (string, error) {
	u, e := url.Parse(strings.TrimSpace(raw))
	if e != nil || u.Scheme != "https" || u.User != nil || u.Fragment != "" {
		return "", ErrInvalidEndpoint
	}
	host := strings.ToLower(strings.TrimSuffix(u.Hostname(), "."))
	if len(host) > 253 || !strings.Contains(host, ".") || net.ParseIP(host) != nil {
		return "", ErrInvalidEndpoint
	}
	for _, s := range []string{".alt", ".arpa", ".example", ".internal", ".invalid", ".local", ".localdomain", ".localhost", ".onion", ".test"} {
		if strings.HasSuffix(host, s) {
			return "", ErrInvalidEndpoint
		}
	}
	if host == "example.com" || host == "example.net" || host == "example.org" {
		return "", ErrInvalidEndpoint
	}
	for _, label := range strings.Split(host, ".") {
		if label == "" || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return "", ErrInvalidEndpoint
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return "", ErrInvalidEndpoint
			}
		}
	}
	port := u.Port()
	u.Host = host
	if port != "" {
		u.Host = net.JoinHostPort(host, port)
	}
	u.RawQuery = ""
	u.Path = strings.TrimRight(u.Path, "/")
	return u.String(), nil
}

// NewPublicHTTPClient never delegates a second DNS lookup to the socket dialer.
// The original URL hostname remains the TLS SNI/certificate authority. Redirects
// are returned to the caller, so credentials cannot follow a changed origin.
func NewPublicHTTPClient(resolver AddressResolver) *http.Client {
	v := NewPublicDNSValidator(resolver, 64)
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.Proxy = nil
	tr.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	tr.TLSHandshakeTimeout = 10 * time.Second
	tr.ResponseHeaderTimeout = 10 * time.Second
	tr.IdleConnTimeout = 30 * time.Second
	tr.MaxConnsPerHost = 16
	tr.MaxIdleConns = 128
	tr.MaxIdleConnsPerHost = 8
	tr.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, e := net.SplitHostPort(address)
		if e != nil {
			return nil, e
		}
		base := "https://" + net.JoinHostPort(host, port)
		if _, e = NormalizePublicRemoteBase(base); e != nil {
			return nil, e
		}
		ip, e := v.Validate(ctx, base)
		if e != nil {
			return nil, e
		}
		return (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext(ctx, network, net.JoinHostPort(ip, port))
	}
	return &http.Client{Transport: tr, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}
