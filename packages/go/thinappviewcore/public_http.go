package thinappviewcore

import (
	"context"
	"crypto/tls"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// PublicHTTP pins each request to a DNS-admitted public IP. TLS still validates
// the publisher hostname. It never accepts a redirect without fresh admission.
type PublicHTTP struct {
	DNS *gatewaycore.PublicDNSValidator
}

func (h PublicHTTP) Get(ctx context.Context, raw string, headers http.Header, maxBytes, redirects int) (int, http.Header, []byte, error) {
	status, resultHeaders, body, _, err := h.GetWithURL(ctx, raw, headers, maxBytes, redirects)
	return status, resultHeaders, body, err
}
func (h PublicHTTP) GetWithURL(ctx context.Context, raw string, headers http.Header, maxBytes, redirects int) (int, http.Header, []byte, string, error) {
	if maxBytes <= 0 || redirects < 0 || redirects > 10 {
		return 0, nil, nil, "", errors.New("invalid public request bounds")
	}
	dns := h.DNS
	if dns == nil {
		dns = gatewaycore.NewPublicDNSValidator(nil, 64)
	}
	current := raw
	for attempt := 0; attempt <= redirects; attempt++ {
		parsed, err := url.Parse(current)
		if err != nil || parsed.User != nil {
			return 0, nil, nil, "", gatewaycore.ErrInvalidEndpoint
		}
		address, err := dns.Validate(ctx, current)
		if err != nil {
			return 0, nil, nil, "", err
		}
		port := parsed.Port()
		if port == "" {
			port = "443"
		}
		transport := &http.Transport{Proxy: nil, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, ServerName: parsed.Hostname()}, DialContext: func(c context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 15 * time.Second}).DialContext(c, network, net.JoinHostPort(address, port))
		}, TLSHandshakeTimeout: 15 * time.Second, ResponseHeaderTimeout: 15 * time.Second, DisableKeepAlives: true}
		client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, current, nil)
		if err != nil {
			return 0, nil, nil, "", err
		}
		req.Header = headers.Clone()
		if attempt > 0 {
			req.Header.Del("If-None-Match")
			req.Header.Del("If-Modified-Since")
		}
		response, err := client.Do(req)
		if err != nil {
			transport.CloseIdleConnections()
			return 0, nil, nil, "", err
		}
		if response.StatusCode >= 300 && response.StatusCode <= 399 && response.StatusCode != 304 {
			response.Body.Close()
			transport.CloseIdleConnections()
			if attempt == redirects {
				return 0, nil, nil, "", errors.New("public request redirect limit")
			}
			location, err := response.Location()
			if err != nil {
				return 0, nil, nil, "", err
			}
			current = location.String()
			continue
		}
		body, err := io.ReadAll(io.LimitReader(response.Body, int64(maxBytes)+1))
		response.Body.Close()
		transport.CloseIdleConnections()
		if err != nil {
			return 0, nil, nil, "", err
		}
		if len(body) > maxBytes {
			return 0, nil, nil, "", errors.New("public response size limit")
		}
		return response.StatusCode, response.Header, body, current, nil
	}
	return 0, nil, nil, "", errors.New("public request redirect limit")
}
func ValidatePDSBase(raw string) string {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Scheme != "https" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return ""
	}
	host := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
	if host == "" || len(host) > 253 || !strings.Contains(host, ".") || net.ParseIP(host) != nil {
		return ""
	}
	for _, suffix := range []string{".alt", ".arpa", ".example", ".internal", ".invalid", ".local", ".localdomain", ".localhost", ".onion", ".test"} {
		if strings.HasSuffix(host, suffix) {
			return ""
		}
	}
	for _, example := range []string{"example.com", "example.net", "example.org"} {
		if host == example || strings.HasSuffix(host, "."+example) {
			return ""
		}
	}
	for _, label := range strings.Split(host, ".") {
		if label == "" || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return ""
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return ""
			}
		}
	}
	port := u.Port()
	u.Host = host
	if port != "" {
		u.Host = net.JoinHostPort(host, port)
	}
	u.Path = ""
	return strings.TrimRight(u.String(), "/")
}
