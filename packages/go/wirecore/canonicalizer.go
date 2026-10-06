package wirecore

// Forms HTTPS article identities, normalizes host/default ports/path, removes fragments
// and known tracking parameters, and sorts semantic query pairs. Literal plus signs retain
// Foundation semantics; the canonical URL is SHA-256 keyed. Identity normalization is not
// network admission.

import (
	"crypto/sha256"
	"encoding/hex"
	"net"
	"net/url"
	"sort"
	"strings"
)

const CanonicalizerVersion = "canonical-url-v1"

// CanonicalIdentity pairs a normalized article URL with its url: SHA-256 key.
type CanonicalIdentity struct {
	CanonicalKey string `json:"canonicalKey"`
	CanonicalURL string `json:"canonicalURL"`
}

var trackingNames = map[string]bool{"dclid": true, "fbclid": true, "gclid": true, "igshid": true, "mc_cid": true, "mc_eid": true, "msclkid": true}

// Canonicalize retains Foundation's literal plus signs in query values. Go's
// form-query parser cannot be used here because it turns '+' into a space.
func Canonicalize(raw string) *CanonicalIdentity {
	uRL, err := url.Parse(raw)
	if err != nil || uRL.User != nil || uRL.Opaque != "" || uRL.Hostname() == "" {
		return nil
	}
	scheme := strings.ToLower(uRL.Scheme)
	if scheme != "http" && scheme != "https" {
		return nil
	}
	uRL.Scheme = "https"
	host, port := strings.ToLower(uRL.Hostname()), uRL.Port()
	if port == "80" || port == "443" {
		port = ""
	}
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	if port != "" {
		host = net.JoinHostPort(strings.Trim(host, "[]"), port)
	}
	uRL.Host, uRL.Fragment, uRL.RawFragment = host, "", ""
	path := uRL.EscapedPath()
	if path == "" {
		path = "/"
	}
	for len(path) > 1 && strings.HasSuffix(path, "/") {
		path = strings.TrimSuffix(path, "/")
	}
	uRL.Path, err = url.PathUnescape(path)
	if err != nil {
		return nil
	}
	uRL.RawPath = path
	type queryItem struct {
		name, value string
		hasValue    bool
	}
	items := []queryItem{}
	if uRL.RawQuery != "" {
		for _, part := range strings.Split(uRL.RawQuery, "&") {
			queryName, queryValue, found := strings.Cut(part, "=")
			queryName, err = url.PathUnescape(queryName)
			if err != nil {
				return nil
			}
			queryValue, err = url.PathUnescape(queryValue)
			if err != nil {
				return nil
			}
			if lower := strings.ToLower(queryName); strings.HasPrefix(lower, "utm_") || trackingNames[lower] {
				continue
			}
			items = append(items, queryItem{queryName, queryValue, found})
		}
	}
	sort.SliceStable(items, func(itemIndex, comparisonIndex int) bool {
		if items[itemIndex].name != items[comparisonIndex].name {
			return items[itemIndex].name < items[comparisonIndex].name
		}
		return items[itemIndex].value < items[comparisonIndex].value
	})
	escape := func(text string) string {
		// URLComponents queryItems allow URI query characters except '&'/'='.
		var out strings.Builder
		const digits = "0123456789ABCDEF"
		for _, octet := range []byte(text) {
			if octet >= 'a' && octet <= 'z' || octet >= 'A' && octet <= 'Z' || octet >= '0' && octet <= '9' || strings.ContainsRune("-._~!$'()*+,;:@/?", rune(octet)) {
				out.WriteByte(octet)
			} else {
				out.WriteByte('%')
				out.WriteByte(digits[octet>>4])
				out.WriteByte(digits[octet&15])
			}
		}
		return out.String()
	}
	parts := make([]string, 0, len(items))
	for _, queryItem2 := range items {
		part := escape(queryItem2.name)
		if queryItem2.hasValue {
			part += "=" + escape(queryItem2.value)
		}
		parts = append(parts, part)
	}
	uRL.RawQuery = strings.Join(parts, "&")
	uRL.ForceQuery = false
	canonical := uRL.String()
	hash := sha256.Sum256([]byte(canonical))
	return &CanonicalIdentity{"url:" + hex.EncodeToString(hash[:]), canonical}
}
