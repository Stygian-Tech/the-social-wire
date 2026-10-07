package gatewaycore

import (
	"context"
	"encoding/json"
	"errors"
	jose "github.com/go-jose/go-jose/v4"
	"golang.org/x/sync/singleflight"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

var ErrAuthentication = errors.New("invalid or stale ATProto OAuth access token")
var ErrAuthDependency = errors.New("ATProto authentication dependency unavailable")
var ErrNoPublicJWKS = errors.New("authoritative issuer has no public JWKS")

type AccessToken struct {
	DID, JKT, Issuer, ClientID, AZP string
	Audiences                       []string
	ExpiresAt                       time.Time
}

func DecodeAccessCandidate(token string, now time.Time) (AccessToken, error) {
	if len(token) == 0 || len(token) > 32768 {
		return AccessToken{}, ErrAuthentication
	}
	raw, e := DecodePayload(token)
	if e != nil {
		return AccessToken{}, ErrAuthentication
	}
	get := func(k string) string { var s string; json.Unmarshal(raw[k], &s); return strings.TrimSpace(s) }
	var exp float64
	var cnf struct {
		JKT string `json:"jkt"`
	}
	if json.Unmarshal(raw["exp"], &exp) != nil || json.Unmarshal(raw["cnf"], &cnf) != nil || exp <= float64(now.UnixNano())/1e9 || !strings.HasPrefix(get("sub"), "did:") || strings.TrimSpace(cnf.JKT) == "" {
		return AccessToken{}, ErrAuthentication
	}
	issuer := get("iss")
	if !(strings.HasPrefix(issuer, "http://") || strings.HasPrefix(issuer, "https://") || strings.HasPrefix(issuer, "did:")) {
		return AccessToken{}, ErrAuthentication
	}
	a := AccessToken{DID: get("sub"), JKT: strings.TrimSpace(cnf.JKT), Issuer: issuer, ClientID: get("client_id"), AZP: get("azp"), ExpiresAt: time.Unix(0, int64(exp*1e9))}
	if a.ClientID == "" {
		a.ClientID = get("clientId")
	}
	var one string
	if json.Unmarshal(raw["aud"], &one) == nil {
		a.Audiences = []string{one}
	} else {
		json.Unmarshal(raw["aud"], &a.Audiences)
	}
	return a, nil
}

type jsonCacheEntry struct {
	data    []byte
	status  int
	expires time.Time
}
type authority struct {
	PDS                           string
	Issuers, AuthorizationServers []string
}
type TokenVerifier struct {
	Lifetime                 *AuthLifetime
	Client                   *http.Client
	PLCURL, SupplementalJWKS string
	mu                       sync.Mutex
	cache                    map[string]jsonCacheEntry
	group                    singleflight.Group
	inFlight                 int
	waiters                  map[string]int
}

func (v *TokenVerifier) fetch(ctx context.Context, target string, maximum int) ([]byte, int, error) {
	if _, e := NormalizePublicRemoteBase(target); e != nil {
		return nil, 0, ErrAuthentication
	}
	deadline, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	r, e := http.NewRequestWithContext(deadline, "GET", target, nil)
	if e != nil {
		return nil, 0, e
	}
	r.Header.Set("Accept", "application/json")
	resp, e := v.Client.Do(r)
	if e != nil {
		return nil, 0, ErrAuthDependency
	}
	defer resp.Body.Close()
	if resp.StatusCode == 429 || resp.StatusCode >= 500 {
		return nil, resp.StatusCode, ErrAuthDependency
	}
	if resp.StatusCode != 200 {
		return nil, resp.StatusCode, nil
	}
	data, e := io.ReadAll(io.LimitReader(resp.Body, int64(maximum+1)))
	if e != nil {
		return nil, resp.StatusCode, ErrAuthDependency
	}
	if len(data) > maximum {
		return nil, resp.StatusCode, ErrAuthentication
	}
	return data, resp.StatusCode, nil
}

// Cache only public discovery/key material, never a token-authentication decision.
func (v *TokenVerifier) cachedFetch(ctx context.Context, target string, maximum int, refresh bool) ([]byte, int, error) {
	v.mu.Lock()
	old, ok := v.cache[target]
	if ok && !refresh && old.expires.After(time.Now()) {
		v.mu.Unlock()
		return old.data, old.status, nil
	}
	if v.waiters == nil {
		v.waiters = map[string]int{}
	}
	if v.waiters[target] >= 256 || (v.waiters[target] == 0 && len(v.waiters) >= 64) {
		v.mu.Unlock()
		return nil, 0, ErrAuthDependency
	}
	v.waiters[target]++
	v.mu.Unlock()
	defer func() {
		v.mu.Lock()
		v.waiters[target]--
		if v.waiters[target] == 0 {
			delete(v.waiters, target)
		}
		v.mu.Unlock()
	}()
	ch := v.group.DoChan(target, func() (any, error) {
		lifetime, finish, open := v.Lifetime.begin()
		if !open {
			return nil, ErrAuthDependency
		}
		defer finish()
		v.mu.Lock()
		current, found := v.cache[target]
		if found && current.expires.After(time.Now()) && (!refresh || !current.expires.Equal(old.expires)) {
			v.mu.Unlock()
			return current, nil
		}
		if v.inFlight >= 64 {
			v.mu.Unlock()
			return nil, ErrAuthDependency
		}
		v.inFlight++
		v.mu.Unlock()
		defer func() { v.mu.Lock(); v.inFlight--; v.mu.Unlock() }()
		load, cancel := context.WithTimeout(lifetime, 10*time.Second)
		defer cancel()
		data, status, e := v.fetch(load, target, maximum)
		if e != nil {
			return nil, e
		}
		ttl := 300 * time.Second
		if status != 200 {
			ttl = 60 * time.Second
		}
		item := jsonCacheEntry{data, status, time.Now().Add(ttl)}
		v.mu.Lock()
		defer v.mu.Unlock()
		if v.cache == nil {
			v.cache = map[string]jsonCacheEntry{}
		}
		delete(v.cache, target)
		cost := len(target) + len(data)
		for key, entry := range v.cache {
			if entry.expires.Before(time.Now()) {
				delete(v.cache, key)
			} else {
				cost += len(key) + len(entry.data)
			}
		}
		for len(v.cache) >= 10000 || cost > 16*1024*1024 {
			var oldest string
			var expiry time.Time
			for key, entry := range v.cache {
				if oldest == "" || entry.expires.Before(expiry) {
					oldest = key
					expiry = entry.expires
				}
			}
			if oldest == "" {
				return item, nil
			}
			cost -= len(oldest) + len(v.cache[oldest].data)
			delete(v.cache, oldest)
		}
		v.cache[target] = item
		return item, nil
	})
	select {
	case <-ctx.Done():
		return nil, 0, ctx.Err()
	case result := <-ch:
		if result.Err != nil {
			return nil, 0, result.Err
		}
		item := result.Val.(jsonCacheEntry)
		return item.data, item.status, nil
	}
}

func (v *TokenVerifier) resolveAuthority(ctx context.Context, did string) (authority, error) {
	return v.resolveAuthorityMode(ctx, did, false)
}
func (v *TokenVerifier) resolveAuthorityMode(ctx context.Context, did string, fresh bool) (authority, error) {
	fetch := func(target string, maximum int) ([]byte, int, error) {
		if fresh {
			return v.fetch(ctx, target, maximum)
		}
		return v.cachedFetch(ctx, target, maximum, false)
	}
	if !strings.HasPrefix(did, "did:") {
		return authority{}, ErrAuthentication
	}
	raw, status, e := fetch(strings.TrimRight(v.PLCURL, "/")+"/"+url.PathEscape(did), 262144)
	if e != nil {
		return authority{}, e
	}
	if status != 200 {
		return authority{}, ErrAuthentication
	}
	var doc struct {
		Service []struct{ ID, Type, ServiceEndpoint string }
	}
	if json.Unmarshal(raw, &doc) != nil {
		return authority{}, ErrAuthentication
	}
	a := authority{}
	for _, s := range doc.Service {
		base, e := NormalizePublicRemoteBase(s.ServiceEndpoint)
		if e != nil {
			continue
		}
		if s.ID == "#atproto_pds" || s.Type == "AtprotoPersonalDataServer" {
			a.PDS = base
		}
		kind := strings.ToLower(s.Type)
		if strings.Contains(kind, "oauth") || strings.Contains(kind, "openid") || strings.Contains(kind, "authserver") {
			a.Issuers = append(a.Issuers, base)
		}
	}
	if a.PDS == "" {
		return authority{}, ErrAuthentication
	}
	a.Issuers = append(a.Issuers, a.PDS)
	meta, status, e := fetch(a.PDS+"/.well-known/oauth-protected-resource", 65536)
	if e != nil {
		return authority{}, e
	}
	if status == 200 {
		var m struct {
			Servers []string `json:"authorization_servers"`
		}
		if json.Unmarshal(meta, &m) == nil {
			for _, s := range m.Servers {
				if base, e := NormalizePublicRemoteBase(s); e == nil {
					a.Issuers = append(a.Issuers, base)
					a.AuthorizationServers = append(a.AuthorizationServers, base)
				}
			}
		}
	}
	return a, nil
}
func verifyKeySet(token string, raw []byte) error {
	var set jose.JSONWebKeySet
	if json.Unmarshal(raw, &set) != nil {
		return ErrAuthentication
	}
	if len(set.Keys) == 0 {
		return ErrNoPublicJWKS
	}
	signed, e := jose.ParseSignedCompact(token, []jose.SignatureAlgorithm{jose.ES256, jose.ES384, jose.ES512, jose.EdDSA, jose.RS256, jose.RS384, jose.RS512, jose.PS256, jose.PS384, jose.PS512})
	if e != nil {
		return ErrAuthentication
	}
	for _, key := range set.Keys {
		if !key.IsPublic() || !key.Valid() {
			continue
		}
		if len(signed.Signatures) != 1 {
			continue
		}
		if kid := signed.Signatures[0].Header.KeyID; kid != "" && key.KeyID != kid {
			continue
		}
		if key.Algorithm != "" && key.Algorithm != signed.Signatures[0].Header.Algorithm {
			continue
		}
		if _, e := signed.Verify(key); e == nil {
			return nil
		}
	}
	return ErrAuthentication
}
func (v *TokenVerifier) Verify(ctx context.Context, token string, now time.Time) (AccessToken, error) {
	a, e := DecodeAccessCandidate(token, now)
	if e != nil {
		return a, e
	}
	var supplemental jose.JSONWebKeySet
	hasSupplemental := json.Unmarshal([]byte(v.SupplementalJWKS), &supplemental) == nil && len(supplemental.Keys) > 0
	if hasSupplemental && verifyKeySet(token, []byte(v.SupplementalJWKS)) == nil {
		return a, nil
	}
	issuer, e := NormalizePublicRemoteBase(a.Issuer)
	if e != nil {
		return a, ErrAuthentication
	}
	auth, e := v.resolveAuthority(ctx, a.DID)
	if e != nil {
		return a, e
	}
	trusted := false
	for _, i := range auth.Issuers {
		trusted = trusted || i == issuer
	}
	if !trusted {
		return a, ErrAuthentication
	}
	last := error(ErrNoPublicJWKS)
	for _, suffix := range []string{"/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"} {
		raw, status, e := v.cachedFetch(ctx, issuer+suffix, 65536, false)
		if e != nil {
			return a, e
		}
		if status != 200 {
			continue
		}
		var m struct {
			Issuer  string          `json:"issuer"`
			JWKSURI string          `json:"jwks_uri"`
			JWKS    json.RawMessage `json:"jwks"`
		}
		if json.Unmarshal(raw, &m) != nil {
			continue
		}
		actual, e := NormalizePublicRemoteBase(m.Issuer)
		if e != nil || actual != issuer {
			continue
		}
		if len(m.JWKS) > 0 {
			e = verifyKeySet(token, m.JWKS)
			if e == nil {
				return a, nil
			}
			if !errors.Is(e, ErrNoPublicJWKS) {
				last = e
			}
		}
		if m.JWKSURI == "" {
			continue
		}
		base, _ := url.Parse(issuer + "/")
		ref, e := url.Parse(m.JWKSURI)
		if e != nil {
			continue
		}
		target := base.ResolveReference(ref)
		if target.Scheme != base.Scheme || !strings.EqualFold(target.Host, base.Host) {
			continue
		}
		keys, status, e := v.cachedFetch(ctx, target.String(), 524288, false)
		if e != nil {
			return a, e
		}
		if status != 200 {
			last = ErrAuthentication
			continue
		}
		e = verifyKeySet(token, keys)
		if e == nil {
			return a, nil
		}
		last = e
		if errors.Is(e, ErrAuthentication) {
			keys, status, e = v.cachedFetch(ctx, target.String(), 524288, true)
			if e != nil {
				return a, e
			}
			if status == 200 {
				e = verifyKeySet(token, keys)
				if e == nil {
					return a, nil
				}
				last = e
			}
		}
		break
	}
	if hasSupplemental && errors.Is(last, ErrNoPublicJWKS) {
		last = ErrAuthentication
	}
	return a, last
}
