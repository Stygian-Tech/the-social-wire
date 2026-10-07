package gatewaycore

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"encoding/json"
	"errors"
	jose "github.com/go-jose/go-jose/v4"
	"math"
	"net/http"
	"strings"
	"sync"
	"time"
)

var ErrDPoP = errors.New("invalid DPoP proof for this request")

type VerifiedDPoP struct {
	Thumbprint, JTI string
	ValidUntil      time.Time
}

func CanonicalHTU(r *http.Request) string {
	host := strings.TrimSpace(r.Host)
	scheme := strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-Proto"), ",")[0])
	if scheme == "" {
		scheme = "https"
		if strings.HasPrefix(strings.ToLower(host), "localhost") || strings.HasPrefix(host, "127.") {
			scheme = "http"
		}
	}
	path := r.URL.EscapedPath()
	if path == "" {
		path = "/"
	}
	return scheme + "://" + host + path
}
func VerifyDPoP(proof, method, htu, accessToken, jkt string, at time.Time) (VerifiedDPoP, error) {
	fail := func() (VerifiedDPoP, error) { return VerifiedDPoP{}, ErrDPoP }
	parts := strings.Split(proof, ".")
	if len(parts) != 3 || strings.TrimSpace(jkt) == "" {
		return fail()
	}
	raw, err := Base64URLDecode(parts[0])
	if err != nil {
		return fail()
	}
	var head struct {
		Alg, Typ string
		JWK      json.RawMessage
	}
	if json.Unmarshal(raw, &head) != nil || head.Alg != "ES256" || (head.Typ != "" && !strings.EqualFold(strings.TrimSpace(head.Typ), "dpop+jwt")) {
		return fail()
	}
	var key jose.JSONWebKey
	if json.Unmarshal(head.JWK, &key) != nil || !key.IsPublic() || !key.Valid() {
		return fail()
	}
	ec, ok := key.Key.(*ecdsa.PublicKey)
	if !ok || ec.Curve != elliptic.P256() {
		return fail()
	}
	signed, err := jose.ParseSignedCompact(proof, []jose.SignatureAlgorithm{jose.ES256})
	if err != nil {
		return fail()
	}
	payload, err := signed.Verify(key)
	if err != nil {
		return fail()
	}
	var claims struct {
		IAT                float64  `json:"iat"`
		EXP                *float64 `json:"exp"`
		JTI, HTM, HTU, ATH string
	}
	if json.Unmarshal(payload, &claims) != nil || claims.IAT <= 0 || math.IsNaN(claims.IAT) || math.IsInf(claims.IAT, 0) || strings.TrimSpace(claims.JTI) == "" {
		return fail()
	}
	instant := time.Unix(0, int64(claims.IAT*1e9))
	if at.Sub(instant).Abs() > 120*time.Second {
		return fail()
	}
	if claims.EXP != nil && *claims.EXP <= float64(at.Add(-120*time.Second).UnixNano())/1e9 {
		return fail()
	}
	trimFragment := func(s string) string {
		s = strings.TrimSpace(s)
		if i := strings.IndexByte(s, '#'); i >= 0 {
			s = s[:i]
		}
		return s
	}
	if !strings.EqualFold(claims.HTM, method) || !strings.EqualFold(trimFragment(claims.HTU), trimFragment(htu)) {
		return fail()
	}
	thumb, err := key.Thumbprint(crypto.SHA256)
	if err != nil || Base64URLEncode(thumb) != strings.TrimSpace(jkt) {
		return fail()
	}
	ath, err := Base64URLDecode(strings.TrimSpace(claims.ATH))
	if err != nil || Base64URLEncode(ath) != AccessTokenATH(accessToken) {
		return fail()
	}
	return VerifiedDPoP{Base64URLEncode(thumb), claims.JTI, instant.Add(120 * time.Second)}, nil
}

// DPoPReplayGuard bounds admission and rejects capacity exhaustion rather than
// evicting live entries. Keep one process-lifetime guard across handler rebuilds.
type DPoPReplayGuard struct {
	mu             sync.Mutex
	entries        map[string]time.Time
	MaximumEntries int
}

func (g *DPoPReplayGuard) Consume(proof VerifiedDPoP, at time.Time) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.entries == nil {
		g.entries = map[string]time.Time{}
	}
	for k, v := range g.entries {
		if v.Before(at) {
			delete(g.entries, k)
		}
	}
	key := proof.Thumbprint + ":" + proof.JTI
	if _, ok := g.entries[key]; ok {
		return ErrDPoP
	}
	limit := g.MaximumEntries
	if limit == 0 {
		limit = 20000
	}
	if len(g.entries) >= limit {
		return ErrDPoP
	}
	until := at.Add(120 * time.Second)
	if proof.ValidUntil.After(until) {
		until = proof.ValidUntil
	}
	g.entries[key] = until
	return nil
}
