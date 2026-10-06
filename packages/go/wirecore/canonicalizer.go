package wirecore

import (
	"crypto/sha256"
	"encoding/hex"
	"net"
	"net/url"
	"sort"
	"strings"
)

const CanonicalizerVersion = "canonical-url-v1"

type CanonicalIdentity struct {
	CanonicalKey string `json:"canonicalKey"`
	CanonicalURL string `json:"canonicalURL"`
}

var trackingNames = map[string]bool{"dclid": true, "fbclid": true, "gclid": true, "igshid": true, "mc_cid": true, "mc_eid": true, "msclkid": true}

// Canonicalize retains Foundation's literal plus signs in query values. Go's
// form-query parser cannot be used here because it turns '+' into a space.
func Canonicalize(raw string) *CanonicalIdentity {
	u, err := url.Parse(raw)
	if err != nil || u.User != nil || u.Opaque != "" || u.Hostname() == "" {
		return nil
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "http" && scheme != "https" {
		return nil
	}
	u.Scheme = "https"
	host, port := strings.ToLower(u.Hostname()), u.Port()
	if port == "80" || port == "443" {
		port = ""
	}
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	if port != "" {
		host = net.JoinHostPort(strings.Trim(host, "[]"), port)
	}
	u.Host, u.Fragment, u.RawFragment = host, "", ""
	path := u.EscapedPath()
	if path == "" {
		path = "/"
	}
	for len(path) > 1 && strings.HasSuffix(path, "/") {
		path = strings.TrimSuffix(path, "/")
	}
	u.Path, err = url.PathUnescape(path)
	if err != nil {
		return nil
	}
	u.RawPath = path
	type queryItem struct {
		name, value string
		hasValue    bool
	}
	items := []queryItem{}
	if u.RawQuery != "" {
		for _, part := range strings.Split(u.RawQuery, "&") {
			n, v, found := strings.Cut(part, "=")
			n, err = url.PathUnescape(n)
			if err != nil {
				return nil
			}
			v, err = url.PathUnescape(v)
			if err != nil {
				return nil
			}
			if lower := strings.ToLower(n); strings.HasPrefix(lower, "utm_") || trackingNames[lower] {
				continue
			}
			items = append(items, queryItem{n, v, found})
		}
	}
	sort.SliceStable(items, func(i, j int) bool {
		if items[i].name != items[j].name {
			return items[i].name < items[j].name
		}
		return items[i].value < items[j].value
	})
	escape := func(s string) string {
		// URLComponents queryItems allow URI query characters except '&'/'='.
		var out strings.Builder
		const digits = "0123456789ABCDEF"
		for _, b := range []byte(s) {
			if b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || strings.ContainsRune("-._~!$'()*+,;:@/?", rune(b)) {
				out.WriteByte(b)
			} else {
				out.WriteByte('%')
				out.WriteByte(digits[b>>4])
				out.WriteByte(digits[b&15])
			}
		}
		return out.String()
	}
	parts := make([]string, 0, len(items))
	for _, q := range items {
		p := escape(q.name)
		if q.hasValue {
			p += "=" + escape(q.value)
		}
		parts = append(parts, p)
	}
	u.RawQuery = strings.Join(parts, "&")
	u.ForceQuery = false
	canonical := u.String()
	hash := sha256.Sum256([]byte(canonical))
	return &CanonicalIdentity{"url:" + hex.EncodeToString(hash[:]), canonical}
}
