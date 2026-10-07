package edge

import (
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"net/http"
	"time"
)

var forbiddenHeaders = []string{"Authorization", "Cookie", "DPoP", "X-ATProto-Upstream-DPoP", "X-Wire-Moderation-DPoP", "X-SocialWire-Gateway-DID", "X-SocialWire-Gateway-Timestamp", "X-SocialWire-Gateway-Signature"}

func (c *Handler) authenticate(r *http.Request, now time.Time) bool {
	for _, name := range forbiddenHeaders {
		if _, exists := r.Header[http.CanonicalHeaderKey(name)]; exists {
			return false
		}
	}
	get := func(name string) (string, bool) {
		values := r.Header.Values(name)
		return r.Header.Get(name), len(values) == 1 && values[0] != ""
	}
	service, ok := get(wirecore.CorpusServiceHeader)
	if !ok {
		return false
	}
	timestamp, ok := get(wirecore.CorpusTimestampHeader)
	if !ok {
		return false
	}
	nonce, ok := get(wirecore.CorpusNonceHeader)
	if !ok {
		return false
	}
	signature, ok := get(wirecore.CorpusSignatureHeader)
	if !ok {
		return false
	}
	headers := wirecore.CorpusServiceHeaders{ServiceID: service, Timestamp: timestamp, Nonce: nonce, Signature: signature}
	if values := r.Header.Values(wirecore.CorpusBodyDigestHeader); len(values) > 0 {
		if len(values) != 1 {
			return false
		}
		headers.BodyDigest = &values[0]
	}
	target := r.URL.EscapedPath()
	if r.URL.RawQuery != "" {
		target += "?" + r.URL.RawQuery
	}
	if wirecore.VerifyCorpusRequest([]byte(c.Config.SharedSecret), c.Config.AllowedServiceID, r.Method, target, headers, now) != nil {
		return false
	}
	return c.Replay.Consume(nonce, now)
}
